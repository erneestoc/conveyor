#!/usr/bin/env bash
# Fleet load test on the AWS trial: N Fargate generator tasks (deploy/trial/loadgen.tf), each
# replaying real builds through the NLB over TLS. Prints every task's summary when all end.
#   bench/fleet.sh LABEL TASKS "--tls --streams 500 --duration-s 1800 --delay-ms 500 --retries 5"
# Needs the terraform user's keys (AWS_* in the environment, region us-east-1).
set -euo pipefail
label=$1; tasks=$2; args=$3
name=conveyor-trial; region=us-east-1
key=$(aws ssm get-parameter --region $region --name /$name/api-key --with-decryption --query Parameter.Value --output text)
tf=$(cd "$(dirname "$0")/../deploy/trial" && terraform output -json)
subnets=$(echo "$tf" | python3 -c "import json,sys; print(','.join(json.load(sys.stdin)['builder_subnets']['value']))")
sg=$(echo "$tf" | python3 -c "import json,sys; print(json.load(sys.stdin)['builder_sg']['value'])")
overrides=$(python3 -c "import json,sys; print(json.dumps({'containerOverrides':[{'name':'loadgen','environment':[{'name':'LOADGEN_ARGS','value':sys.argv[1]},{'name':'LOADGEN_API_KEY','value':sys.argv[2]}]}]}))" "$args" "$key")
start=$(date -u +%s)
arns=$(aws ecs run-task --region $region --cluster $name-builders --task-definition $name-loadgen --launch-type FARGATE --count "$tasks" \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=ENABLED}" \
  --overrides "$overrides" --query 'tasks[].taskArn' --output text)
echo "$label: $tasks tasks started $(date -u +%T): $args"
aws ecs wait tasks-stopped --region $region --cluster $name-builders --tasks $arns || true
aws ecs wait tasks-stopped --region $region --cluster $name-builders --tasks $arns || true
echo "stopped $(date -u +%T) after $(( $(date -u +%s) - start )) s"
aws ecs describe-tasks --region $region --cluster $name-builders --tasks $arns --query 'tasks[].containers[0].[exitCode,reason]' --output text | sort | uniq -c
for arn in $arns; do
  id=${arn##*/}
  aws logs get-log-events --region $region --log-group-name /$name/builders --log-stream-name loadgen/loadgen/$id --start-from-head --query 'events[].message' --output text | grep -E "^(builds|events|ack|build) " | sed "s/^/$id: /"
done
