#!/usr/bin/env bash
# After `terraform apply` and a healthy Conveyor: creates the trial project's upload/ingest
# API key and the NativeLink cache endpoint (custom CA) through `bin/conveyor rpc` on one
# Conveyor node via SSM, and stores the key in SSM for the builders.
set -euo pipefail
cd "$(dirname "$0")"
asg=$(terraform output -raw conveyor_asg)
name=${asg%-conveyor}
region=us-east-1
cache_host=cache.rbe.algobien.com
# A node the balancer already considers healthy (the ASG's own status is only EC2 health).
tg=$(aws elbv2 describe-target-groups --region "$region" --names "$name-web" --query 'TargetGroups[0].TargetGroupArn' --output text)
instance=$(aws elbv2 describe-target-health --region "$region" --target-group-arn "$tg" \
  --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id | [0]' --output text)
echo "using instance $instance"
rpc=$(cat <<ELIXIR
p = Conveyor.Projects.get_project_by_slug("default") || Conveyor.Projects.ensure_default_project!()
{:ok, _} = Conveyor.Projects.put_cache_endpoint(p, "$cache_host:50051", %{"tls" => %{"mode" => "custom_ca", "ca_file" => "/etc/conveyor/rbe-ca.crt"}, "headers" => %{}})
{:ok, _key, plaintext} = Conveyor.Projects.create_api_key(p, %{"name" => "trial-builders-#{System.os_time(:second)}", "scopes" => ["ingest", "upload"]})
IO.puts("APIKEY=" <> plaintext)
ELIXIR
)
b64=$(printf '%s' "$rpc" | base64 | tr -d '\n')
params=$(python3 -c 'import json,sys; print(json.dumps({"commands": [sys.argv[1]]}))' \
  "echo $b64 | base64 -d > /tmp/rpc.exs && docker exec -e DIST_PORT_MIN=9101 -e DIST_PORT_MAX=9101 conveyor bin/conveyor rpc \"\$(cat /tmp/rpc.exs)\"")
cmd_id=$(aws ssm send-command --region "$region" --instance-ids "$instance" --document-name AWS-RunShellScript \
  --parameters "$params" --query Command.CommandId --output text)
for _ in $(seq 1 20); do
  status=$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" --query Status --output text 2>/dev/null || echo Pending)
  [[ "$status" == "Success" || "$status" == "Failed" ]] && break
  sleep 3
done
out=$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" --query StandardOutputContent --output text)
err=$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" --query StandardErrorContent --output text)
echo "$out" | grep -v APIKEY || true; [[ -n "$err" ]] && echo "stderr: $err"
key=$(echo "$out" | sed -n 's/^APIKEY=//p')
[[ -n "$key" ]] || { echo "no key returned (status $status)"; exit 1; }
aws ssm put-parameter --region "$region" --name "/$name/api-key" --type SecureString --value "$key" --overwrite >/dev/null
echo "stored /$name/api-key (status $status)"
