#!/usr/bin/env bash
# After `terraform apply` and a healthy Conveyor: creates the trial project's upload/ingest
# API key and the NativeLink cache endpoint (custom CA) through `bin/conveyor rpc` on one
# Conveyor node via SSM, and stores the key in SSM for the builders.
set -euo pipefail
cd "$(dirname "$0")"
name=$(terraform output -raw conveyor_asg | sed 's/-conveyor$//')
region=us-east-1
cache_host=cache.rbe.algobien.com
instance=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$(terraform output -raw conveyor_asg)" \
  --query 'AutoScalingGroups[0].Instances[?HealthStatus==`Healthy`].InstanceId | [0]' --output text)
echo "using instance $instance"
rpc='{:ok, p} = (case Conveyor.Projects.get_project_by_slug("default") do nil -> Conveyor.Projects.ensure_default_project!() |> then(&{:ok, &1}); p -> {:ok, p} end)
{:ok, _} = Conveyor.Projects.put_cache_endpoint(p, "'"$cache_host"':50051", %{"tls" => %{"mode" => "custom_ca", "ca_file" => "/etc/conveyor/rbe-ca.crt"}, "headers" => %{}})
{:ok, _key, plaintext} = Conveyor.Projects.create_api_key(p, %{"name" => "trial-builders", "scopes" => ["ingest", "upload"]})
IO.puts("APIKEY=" <> plaintext)'
cmd_id=$(aws ssm send-command --region "$region" --instance-ids "$instance" --document-name AWS-RunShellScript \
  --parameters "commands=[\"docker exec conveyor bin/conveyor rpc '$(echo "$rpc" | tr '\n' ';' | sed "s/'/'\\\\''/g")'\"]" \
  --query Command.CommandId --output text)
sleep 8
out=$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" --query StandardOutputContent --output text)
err=$(aws ssm get-command-invocation --region "$region" --command-id "$cmd_id" --instance-id "$instance" --query StandardErrorContent --output text)
echo "$out" | grep -v APIKEY; [[ -n "$err" ]] && echo "stderr: $err"
key=$(echo "$out" | sed -n 's/^APIKEY=//p')
[[ -n "$key" ]] || { echo "no key returned"; exit 1; }
aws ssm put-parameter --region "$region" --name "/$name/api-key" --type SecureString --value "$key" --overwrite >/dev/null
echo "stored /$name/api-key"
