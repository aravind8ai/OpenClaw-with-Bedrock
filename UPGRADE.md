# Upgrade Guide: v2026.3.24 → v2026.4.5

OpenClaw v2026.4.5 introduces a plugin-based provider discovery, memory/embeddings support, and a new model runtime. It has breaking changes to Bedrock authentication and config that require manual steps on existing deployments.

Two paths:
- **In-Place Upgrade** — preserves chat history, channel connections, skills, and gateway token (recommended)
- **Fresh Redeploy** — destroy and redeploy via Terraform pipeline

---

## What Changed

| Area | v2026.3.24 | v2026.4.5 |
|------|-----------|-----------|
| Config style | `models.providers` (explicit model list) | `plugins.entries` (auto-discovers Bedrock models) |
| Auth field | `"auth": "aws-sdk"` required | Ignored — auth via env vars |
| API field | `"api": "bedrock-converse-stream"` required | Not needed with plugin config |
| AWS env vars | Not required (SDK default chain) | `AWS_PROFILE=default` required for EC2 IMDS auth |
| Install flags | `--ignore-scripts` on ARM64 | Must NOT use `--ignore-scripts` |

### Why Bedrock auth breaks on EC2

v2026.4.5 checks for `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`, etc. before falling back to the SDK credential chain. On EC2 with IAM roles, none of those are set — credentials come from IMDS — so it fails with:

```
No API key found for amazon-bedrock.
```

Fix: set `AWS_PROFILE=default` in `~/.openclaw/.env`.

---

## Option 1: In-Place Upgrade (Recommended)

Preserves: chat history, channel connections, SOUL.md, skills, cron jobs, gateway token.

### Connect to the instance

```bash
# Get instance ID from Terraform output
INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id)
REGION=$(terraform -chdir=terraform output -raw bedrock_model | xargs -I{} aws configure get region || echo "us-east-1")

# Or look it up by stack tag
REGION="us-east-1"   # your deployment region
STACK_NAME="chatbot-stack"   # your stack name (STACK_NAME variable)
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:openclaw:stack-name,Values=$STACK_NAME" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text --region $REGION)

aws ssm start-session --target $INSTANCE_ID --region $REGION
sudo su - ubuntu
```

### Step 1: Back up

```bash
openclaw --version
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak
cp ~/.openclaw/.env ~/.openclaw/.env.bak 2>/dev/null || true
```

### Step 2: Install v2026.4.5

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Do NOT use --ignore-scripts — v2026.4.5 needs native modules
npm install -g openclaw@2026.4.5 --timeout=300000
openclaw --version
```

### Step 3: Set environment variables

```bash
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

# Loaded by gateway systemd service via EnvironmentFile=
printf 'AWS_PROFILE=default\nAWS_REGION=%s\nAWS_DEFAULT_REGION=%s\n' "$REGION" "$REGION" > ~/.openclaw/.env

# For non-service processes
mkdir -p ~/.config/environment.d
printf 'AWS_REGION=%s\nAWS_DEFAULT_REGION=%s\nAWS_PROFILE=default\n' "$REGION" "$REGION" > ~/.config/environment.d/aws.conf
```

### Step 4: Migrate config

Extract your current token and model, then write the modern plugin-based config:

```bash
TOKEN=$(python3 -c "
import json, os
with open(os.path.expanduser('~/.openclaw/openclaw.json')) as f:
    cfg = json.load(f)
print(cfg['gateway']['auth']['token'])
")

MODEL=$(python3 -c "
import json, os
with open(os.path.expanduser('~/.openclaw/openclaw.json')) as f:
    cfg = json.load(f)
print(cfg['agents']['defaults']['model']['primary'].split('/')[-1])
")

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
      "model": { "primary": "amazon-bedrock/$MODEL" },
      "memorySearch": { "provider": "bedrock", "model": "amazon.titan-embed-text-v2:0" }
    }
  }
}
EOF
```

> If you prefer to keep the legacy `models.providers` config, remove the `"auth": "aws-sdk"` field and ensure `"api": "bedrock-converse-stream"` is present. Without the `api` field, v2026.4.5 defaults to raw HTTP and times out.

### Step 5: Restart gateway

```bash
openclaw gateway install --force
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```

### Step 6: Verify

```bash
openclaw --version
systemctl --user status openclaw-gateway.service --no-pager
journalctl --user -u openclaw-gateway.service -n 30 --no-pager
```

---

## Option 2: Fresh Redeploy via Terraform

> **Warning**: destroys all data — chat history, channel connections (must re-pair), SOUL.md, skills, cron jobs, and gateway token.

### Step 1: Update the version variable

In your GitHub repo settings, update the `OPENCLAW_VERSION` variable (or `terraform.tfvars`) to `2026.4.5`.

### Step 2: Destroy existing infrastructure

Trigger the `terraform-destroy.yml` workflow from GitHub Actions → type `destroy` to confirm.

Or via CLI:
```bash
cd terraform
terraform destroy \
  -var="aws_region=$REGION" \
  -var="stack_name=$STACK_NAME"
```

### Step 3: Clean up SSM parameter

```bash
aws ssm delete-parameter \
  --name "/openclaw/$STACK_NAME/gateway-token" \
  --region $REGION 2>/dev/null || true
```

### Step 4: Redeploy

Push to `main` or trigger `terraform-apply.yml` manually. The setup script automatically uses the modern plugin config and writes `AWS_PROFILE=default` to `~/.openclaw/.env` for v2026.4.5.

### Step 5: Access and reconnect

```bash
# Get instance ID
INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id)

# Start port forwarding
aws ssm start-session \
  --target $INSTANCE_ID \
  --region $REGION \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["18789"],"localPortNumber":["18789"]}'

# Get token
TOKEN=$(aws ssm get-parameter \
  --name /openclaw/$STACK_NAME/gateway-token \
  --with-decryption --query Parameter.Value \
  --output text --region $REGION)

echo "http://localhost:18789/?token=$TOKEN"
```

Reconnect messaging channels via Channels → Add Channel in the Web UI.

---

## Troubleshooting

### "No API key found for amazon-bedrock"

```bash
cat ~/.openclaw/.env  # should contain AWS_PROFILE=default

# If missing:
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
printf 'AWS_PROFILE=default\nAWS_REGION=%s\nAWS_DEFAULT_REGION=%s\n' "$REGION" "$REGION" > ~/.openclaw/.env
systemctl --user restart openclaw-gateway.service
```

### "LLM request timed out"

Legacy config is missing the `api` field:

```bash
python3 << 'EOF'
import json, os
path = os.path.expanduser('~/.openclaw/openclaw.json')
with open(path) as f:
    cfg = json.load(f)
cfg['models']['providers']['amazon-bedrock']['api'] = 'bedrock-converse-stream'
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
print('Fixed')
EOF
systemctl --user restart openclaw-gateway.service
```

### "Cannot find module '@buape/carbon'"

Reinstall without `--ignore-scripts`:

```bash
export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
npm install -g openclaw@2026.4.5 --timeout=300000
openclaw gateway install --force
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```

### Rollback to v2026.3.24

```bash
cp ~/.openclaw/openclaw.json.bak ~/.openclaw/openclaw.json
cp ~/.openclaw/.env.bak ~/.openclaw/.env 2>/dev/null || true

export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
ARCH=$(uname -m)
IGNORE_FLAG=""
[ "$ARCH" = "aarch64" ] && IGNORE_FLAG="--ignore-scripts"
npm install -g openclaw@2026.3.24 --timeout=300000 $IGNORE_FLAG

openclaw gateway install --force
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway.service
```
