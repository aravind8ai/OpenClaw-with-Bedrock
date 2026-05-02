# Troubleshooting Guide

## Quick Reference: Common Commands

### Connect to EC2 Instance

```bash
# Get instance ID from Terraform output
INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id)

# Or look it up directly
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=<stack-name>-instance" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text --region us-east-1)

# Connect via SSM (no SSH needed)
aws ssm start-session --target $INSTANCE_ID --region us-east-1

# Switch to ubuntu user
sudo su - ubuntu
```

### OpenClaw Common Commands

```bash
# Check gateway status
openclaw gateway status

# Restart gateway service
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service

# Check service status
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status openclaw-gateway.service

# View gateway logs
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u openclaw-gateway.service -n 100 -f

# Check configuration
cat ~/.openclaw/openclaw.json | python3 -m json.tool

# Test Bedrock connection
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
aws bedrock-runtime invoke-model \
  --model-id global.amazon.nova-2-lite-v1:0 \
  --body '{"messages":[{"role":"user","content":[{"text":"Hello"}]}],"inferenceConfig":{"maxTokens":100}}' \
  --region $REGION \
  /tmp/test.json && cat /tmp/test.json
```

### View Setup Logs

```bash
# Last 100 lines of setup log
sudo tail -100 /var/log/openclaw-setup.log

# Follow in real time (if still running)
sudo tail -f /var/log/openclaw-setup.log

# Full cloud-init log
sudo cat /var/log/cloud-init-output.log
```

---

## Common Issues

### 1. "No API key found for amazon-bedrock"

**Symptom**: Agent fails with:
```
⚠ Agent failed before reply: No API key found for amazon-bedrock.
Use /login or set an API key environment variable.
```

**Cause**: OpenClaw 2026.4.5+ requires `AWS_PROFILE` env var to discover IAM credentials from the EC2 instance profile. The gateway systemd service doesn't inherit shell env vars, so it's missing at runtime.

**Fix**:

```bash
# SSM into the instance, switch to ubuntu
sudo -u ubuntu bash

# Write AWS_PROFILE to the durable .env file
echo "AWS_PROFILE=default" >> ~/.openclaw/.env

# Restart gateway
systemctl --user restart openclaw-gateway.service
```

> `~/.openclaw/.env` is loaded by the gateway systemd service via `EnvironmentFile=` and survives upgrades.

---

### 2. Cannot Connect via SSM

**Symptom**: `TargetNotConnected` or timeout on `aws ssm start-session`

**Causes**: SSM agent not running, IAM role missing permissions, or security group blocking outbound 443.

```bash
# Check if instance is registered with SSM
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --region us-east-1

# Verify IAM instance profile is attached
aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile' \
  --region us-east-1

# If you have SSH access, restart SSM agent
sudo snap restart amazon-ssm-agent
```

---

### 3. Web UI Shows "Disconnected" or Token Mismatch

**Symptom**: Browser shows "Disconnected from gateway" or "unauthorized: gateway token mismatch"

```bash
# 1. Check port forwarding is running (local machine)
ps aux | grep "start-session.*18789"

# 2. Restart port forwarding
aws ssm start-session \
  --target $INSTANCE_ID \
  --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["18789"],"localPortNumber":["18789"]}'

# 3. Get the correct token from SSM Parameter Store
TOKEN=$(aws ssm get-parameter \
  --name /openclaw/<stack-name>/gateway-token \
  --with-decryption \
  --query Parameter.Value \
  --output text --region us-east-1)
echo "http://localhost:18789/?token=$TOKEN"

# 4. Check gateway is running (on EC2)
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status openclaw-gateway.service

# 5. Restart if needed
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service
```

---

### 4. Model Returns Empty Response

**Symptom**: Message sent, no response or empty response in Web UI

```bash
# 1. Check current model config
cat ~/.openclaw/openclaw.json | python3 -m json.tool | grep -A 5 '"model"'

# 2. Test model directly
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
aws bedrock-runtime invoke-model \
  --model-id global.amazon.nova-2-lite-v1:0 \
  --body '{"messages":[{"role":"user","content":[{"text":"Hello"}]}],"inferenceConfig":{"maxTokens":100}}' \
  --region $REGION \
  /tmp/test.json && cat /tmp/test.json

# 3. Check gateway logs for errors
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u openclaw-gateway.service -n 50 | grep -i error

# 4. Verify model ID has cross-region inference prefix
# ✅ global.amazon.nova-2-lite-v1:0
# ✅ us.amazon.nova-pro-v1:0
# ❌ amazon.nova-2-lite-v1:0  (missing prefix)
```

---

### 5. Bedrock API Errors

**Symptom**: `AccessDeniedException`, `ThrottlingException`, or `ModelNotFound`

```bash
# Verify IAM identity
aws sts get-caller-identity

# List available models
aws bedrock list-foundation-models \
  --by-provider Amazon \
  --region us-east-1 \
  --query 'modelSummaries[?contains(modelId, `nova`)].[modelId,modelLifecycle.status]' \
  --output table

# View gateway logs
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u openclaw-gateway.service -n 50
```

---

### 6. High Costs / Unexpected Bills

```bash
# Check Bedrock costs (last 7 days)
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '7 days ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity DAILY \
  --metrics BlendedCost \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' \
  --region us-east-1

# Set up a cost alert
aws cloudwatch put-metric-alarm \
  --alarm-name bedrock-cost-alert \
  --alarm-description "Alert when Bedrock costs exceed $50" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --evaluation-periods 1 \
  --threshold 50 \
  --comparison-operator GreaterThanThreshold
```

Switch to a cheaper model by updating `OPENCLAW_MODEL` in GitHub Variables and re-running the pipeline. Nova 2 Lite is 90% cheaper than Claude.

---

### 7. Gateway Won't Start

**Symptom**: `systemctl --user status openclaw-gateway.service` shows failed

```bash
# Check logs
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u openclaw-gateway.service -n 100

# Validate config JSON
python3 -m json.tool ~/.openclaw/openclaw.json

# Check if port is already in use
ss -tlnp | grep 18789

# Kill any stale process
pkill -f openclaw

# Restart
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service

# If systemctl fails, start manually
nohup openclaw gateway start > /tmp/gateway.log 2>&1 &
tail -f /tmp/gateway.log
```

---

### 8. Port Forwarding Fails

**Symptom**: `Connection to destination port failed`

```bash
# Verify gateway is listening on EC2
ss -tlnp | grep 18789

# Restart gateway
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service
sleep 5
ss -tlnp | grep 18789

# Kill old port forwarding session (local machine)
pkill -f "start-session.*18789"

# Start fresh
aws ssm start-session \
  --target $INSTANCE_ID \
  --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["18789"],"localPortNumber":["18789"]}'
```

---

### 9. Slow Response Times

```bash
# Check instance load
top

# Check network latency to Bedrock
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
ping bedrock-runtime.$REGION.amazonaws.com
```

To upgrade instance type, update `INSTANCE_TYPE` in GitHub Variables and re-run the pipeline (`terraform-apply.yml`). Recommended upgrade: `c7g.large` → `c7g.xlarge`.

Enabling VPC endpoints (`CREATE_VPC_ENDPOINTS=true`) also reduces latency by keeping Bedrock traffic on the AWS private network.

---

### 10. Cannot Add Messaging Channels

**Symptom**: Error when adding WhatsApp/Telegram/Discord in Web UI

```bash
# Check openclaw version
openclaw --version

# Update to latest
npm update -g openclaw
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service

# Watch logs while adding channel
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u openclaw-gateway.service -f
```

---

### 11. Terraform Deployment Fails

**Symptom**: GitHub Actions pipeline fails during apply

```bash
# Check failed resources in AWS console, or via CLI
aws cloudformation describe-stack-events \
  --stack-name <stack-name> --region us-east-1 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]'

# Common causes:
# - Missing GitHub secret (AWS_ROLE_ARN, TF_STATE_BUCKET, TF_LOCK_TABLE)
# - IAM role doesn't have sufficient permissions
# - S3 state bucket doesn't exist in the target region
# - DynamoDB lock table doesn't exist
```

To destroy a failed stack and retry:
```bash
# Trigger terraform-destroy.yml workflow from GitHub Actions
# Type "destroy" in the confirm input, then re-run terraform-apply.yml
```

---

## Diagnostic Script

Run this on the EC2 instance for a full health snapshot:

```bash
#!/bin/bash
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

echo "=== OpenClaw Health Check ==="
echo "Region: $REGION | Instance: $INSTANCE_ID"
echo ""

echo "--- Service Status ---"
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status openclaw-gateway.service --no-pager
echo ""

echo "--- Port 18789 ---"
ss -tlnp | grep 18789
echo ""

echo "--- Recent Logs ---"
XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -u openclaw-gateway.service -n 20 --no-pager
echo ""

echo "--- Bedrock Test ---"
aws bedrock-runtime invoke-model \
  --model-id global.amazon.nova-2-lite-v1:0 \
  --body '{"messages":[{"role":"user","content":[{"text":"ping"}]}],"inferenceConfig":{"maxTokens":10}}' \
  --region $REGION /tmp/test.json \
  && echo "✓ Bedrock OK" || echo "✗ Bedrock Failed"
```

---

## Reset Configuration

Use this if the config is corrupted:

```bash
#!/bin/bash
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
IMDS_TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
STACK_NAME=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=openclaw:stack-name" \
  --query "Tags[0].Value" --output text --region $REGION)
TOKEN=$(aws ssm get-parameter \
  --name "/openclaw/$STACK_NAME/gateway-token" \
  --with-decryption --query Parameter.Value --output text --region $REGION)

# Stop and backup
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop openclaw-gateway.service
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak.$(date +%s)

# Recreate config
cat > ~/.openclaw/openclaw.json << EOF
{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback",
    "controlUi": { "enabled": true, "allowInsecureAuth": true },
    "auth": { "mode": "token", "token": "$TOKEN" }
  },
  "plugins": {
    "entries": { "amazon-bedrock": { "enabled": true } }
  },
  "agents": {
    "defaults": {
      "model": { "primary": "amazon-bedrock/global.amazon.nova-2-lite-v1:0" }
    }
  }
}
EOF

# Restore env
printf 'AWS_PROFILE=default\nAWS_REGION=%s\nAWS_DEFAULT_REGION=%s\n' \
  "$REGION" "$REGION" > ~/.openclaw/.env

XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart openclaw-gateway.service
echo "✓ Done — http://localhost:18789/?token=$TOKEN"
```

---

## File Locations

```
~/.openclaw/openclaw.json          # Main config
~/.openclaw/.env                   # Environment variables (AWS_PROFILE etc.)
/var/log/openclaw-setup.log        # EC2 setup log
```

Gateway token is stored in SSM Parameter Store at `/openclaw/<stack-name>/gateway-token` — never written to disk.

---

## Support

- [GitHub Issues](https://github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock/issues)
- [OpenClaw Discord](https://discord.gg/openclaw)
- [AWS Bedrock re:Post](https://repost.aws/tags/bedrock)
