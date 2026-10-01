#!/usr/bin/env bash
# Fleet load test on the AWS trial: N Fargate generator tasks (deploy/trial/loadgen.tf), each
# replaying real builds through the NLB over TLS. Prints every task's summary when all end.
#   bench/fleet.sh LABEL TASKS "--tls --streams 125 --duration-s 900 --delay-ms 500 --retries 5"
# Needs the terraform user's keys (AWS_* in the environment, region us-east-1).
set -euo pipefail
label=$1; tasks=$2; args=$3
name=conveyor-trial; region=us-east-1
key=$(aws ssm get-parameter --region $region --name /$name/api-key --with-decryption --query Parameter.Value --output text)
tf=$(cd "$(dirname "$0")/../deploy/trial" && terraform output -json)
subnets=$(echo "$tf" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin)['builder_subnets']['value']))")
sg=$(echo "$tf" | python3 -c "import json,sys; print(json.load(sys.stdin)['builder_sg']['value'])")
# One API key per task (KEYS file, one per line) models many teams: the per-key stream and
# event-rate limits apply per node, so a single key would be throttled at fleet scale.
keys=${KEYS:-}
tmp=$(mktemp -d)
launch() {
  local i=$1 k=$key
  [ -n "$keys" ] && k=$(sed -n "${i}p" "$keys")
  local overrides
  overrides=$(python3 -c "import json,sys; print(json.dumps({'containerOverrides':[{'name':'loadgen','environment':[{'name':'LOADGEN_ARGS','value':sys.argv[1]},{'name':'LOADGEN_API_KEY','value':sys.argv[2]}]}]}))" "$args" "$k")
  aws ecs run-task --region $region --cluster $name-builders --task-definition $name-loadgen --launch-type FARGATE --count 1 \
    --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=ENABLED}" \
    --overrides "$overrides" --query 'tasks[0].taskArn' --output text > "$tmp/$i"
}
# Launches run in parallel batches (80 sequential run-task calls took 16 minutes).
for i in $(seq 1 "$tasks"); do
  launch "$i" &
  if (( i % 10 == 0 )); then wait; fi
done
wait
arns=$(cat "$tmp"/* | tr '\n' ' ')
start=$(date -u +%s)
echo "$label: $tasks tasks started $(date -u +%T): $args"
for group in $(echo $arns | xargs -n 50 | tr ' ' ','); do
  for attempt in 1 2 3 4 5 6; do aws ecs wait tasks-stopped --region $region --cluster $name-builders --tasks ${group//,/ } && break; done
done
echo "stopped $(date -u +%T) after $(( $(date -u +%s) - start )) s"
aws ecs describe-tasks --region $region --cluster $name-builders --tasks $arns --query 'tasks[].containers[0].[exitCode,reason]' --output text | sort | uniq -c
for arn in $arns; do
  id=${arn##*/}
  aws logs get-log-events --region $region --log-group-name /$name/builders --log-stream-name loadgen/loadgen/$id --start-from-head --query 'events[].message' --output text | tr '\t' '\n' | grep -E "^(builds|events|ack|build) " | sed "s/^/$id: /"
done
