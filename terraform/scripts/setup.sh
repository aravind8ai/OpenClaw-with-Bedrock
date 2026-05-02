#!/bin/bash
# OpenClaw setup script — downloaded from S3 and executed by user_data.
# Variables injected via environment by the bootstrap stub in user_data.
# OPENCLAW_MODEL, OPENCLAW_VERSION, ENABLE_SANDBOX, ENABLE_MONITORING,
# STACK_NAME, AWS_REGION are all set before this script runs.

exec > >(tee /var/log/openclaw-setup.log) 2>&1
echo "=========================================="
echo "OpenClaw AWS Native Setup: $(date)"
echo "=========================================="

export DEBIAN_FRONTEND=noninteractive

# ---- Mount data volume ----
echo "[0/9] Mounting data volume..."
DATA_DEVICE=""
for dev in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
  if [ -b "$dev" ]; then DATA_DEVICE="$dev"; break; fi
done
if [ -z "$DATA_DEVICE" ]; then
  DATA_DEVICE=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -v "$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//')" | head -1)
fi
if [ -n "$DATA_DEVICE" ] && [ -b "$DATA_DEVICE" ]; then
  if ! blkid "$DATA_DEVICE" | grep -q ext4; then
    mkfs.ext4 -L openclaw-data "$DATA_DEVICE"
  fi
  mkdir -p /data
  mount "$DATA_DEVICE" /data || { echo "FATAL: failed to mount $DATA_DEVICE"; exit 1; }
  grep -q "$DATA_DEVICE" /etc/fstab || echo "$DATA_DEVICE /data ext4 defaults,nofail 0 2" >> /etc/fstab
  mkdir -p /data/openclaw
  chown ubuntu:ubuntu /data/openclaw
  [ -L /home/ubuntu/.openclaw ] || ln -sf /data/openclaw /home/ubuntu/.openclaw
  mkdir -p /home/ubuntu/.config/environment.d
  echo "OPENCLAW_STATE_DIR=/data/openclaw" >> /home/ubuntu/.config/environment.d/openclaw.conf
else
  echo "FATAL: no data volume found"; exit 1
fi
STATE_DIR=/data/openclaw

# ---- Write config files ----
mkdir -p /opt/openclaw

cat > /opt/openclaw/openclaw-config-legacy.json << 'LEGACYJSON'
{
  "gateway": {
    "mode": "local", "port": 18789, "bind": "loopback",
    "controlUi": { "enabled": true, "allowInsecureAuth": true },
    "auth": { "mode": "token", "token": "GATEWAY_TOKEN_PLACEHOLDER" }
  },
  "models": {
    "providers": {
      "amazon-bedrock": {
        "baseUrl": "https://bedrock-runtime.REGION_PLACEHOLDER.amazonaws.com",
        "api": "bedrock-converse-stream", "auth": "aws-sdk",
        "models": [{ "id": "MODEL_ID_PLACEHOLDER", "name": "Bedrock Model",
          "input": ["text","image"], "contextWindow": 200000, "maxTokens": 8192 }]
      }
    }
  },
  "agents": { "defaults": { "model": { "primary": "amazon-bedrock/MODEL_ID_PLACEHOLDER" } } }
}
LEGACYJSON

cat > /opt/openclaw/openclaw-config-modern.json << 'MODERNJSON'
{
  "gateway": {
    "mode": "local", "port": 18789, "bind": "loopback",
    "controlUi": { "enabled": true, "allowInsecureAuth": true },
    "auth": { "mode": "token", "token": "GATEWAY_TOKEN_PLACEHOLDER" }
  },
  "plugins": { "entries": { "amazon-bedrock": { "enabled": true } } },
  "agents": {
    "defaults": {
      "model": { "primary": "amazon-bedrock/MODEL_ID_PLACEHOLDER" },
      "memorySearch": { "provider": "bedrock", "model": "amazon.titan-embed-text-v2:0" }
    }
  }
}
MODERNJSON

cat > /opt/openclaw/SOUL.md << 'SOULEOF'
# OpenClaw on AWS

You are an AI assistant running on AWS with Amazon Bedrock. You are helpful, concise, and friendly.

## First Conversation

When a user sends their very first message, greet them and help connect a messaging platform:

"Welcome! I'm your AI assistant running on AWS. Which platform would you like to connect?
1. WhatsApp  2. Telegram  3. Discord  4. Slack  5. Feishu/Lark"

## Ongoing Conversations

Be a helpful general-purpose assistant. Be concise. Get to the point.
SOULEOF

cat > /opt/openclaw/ssm-portforward.sh << 'SSMEOF'
#!/bin/bash
IMDS_TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
STACK=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=openclaw:stack-name" --query "Tags[0].Value" --output text --region $REGION)
TOKEN=$(aws ssm get-parameter --name "/openclaw/$STACK/gateway-token" --with-decryption --query Parameter.Value --output text --region $REGION)
echo "Port forward: aws ssm start-session --target $INSTANCE_ID --region $REGION --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"18789\"],\"localPortNumber\":[\"18789\"]}'"
echo "Browser: http://localhost:18789/?token=$TOKEN"
SSMEOF
chmod +x /opt/openclaw/ssm-portforward.sh
chown ubuntu:ubuntu /opt/openclaw/ssm-portforward.sh

# ---- System update ----
echo "[1/9] Updating system..."
apt-get update
apt-get upgrade -y
apt-get install -y unzip curl

# ---- Swap (2GB) ----
echo "[1.1/9] Configuring swap..."
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  sysctl vm.swappiness=10
fi

# ---- Instance metadata (IMDSv2) ----
echo "[*] Detecting instance metadata..."
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
if [ -n "$IMDS_TOKEN" ]; then
  DETECTED_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
fi
AWS_REGION=${DETECTED_REGION:-$AWS_REGION}
INSTANCE_ID=${INSTANCE_ID:-"unknown"}
echo "Region: $AWS_REGION | Instance: $INSTANCE_ID"

# ---- AWS CLI ----
echo "[2/9] Installing AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-$(arch).zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# ---- SSM Agent ----
echo "[3/9] Configuring SSM Agent..."
snap start amazon-ssm-agent || systemctl start amazon-ssm-agent

# ---- Docker (conditional) ----
if [ "$ENABLE_SANDBOX" = "true" ]; then
  echo "[4/9] Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
  systemctl enable docker
  systemctl start docker
  usermod -aG docker ubuntu
else
  echo "[4/9] Skipping Docker (ENABLE_SANDBOX=false)..."
fi

# ---- Node.js via NVM ----
echo "[5/9] Installing Node.js..."
sudo -u ubuntu bash << 'UBUNTU_SCRIPT'
cd ~
NVM_VERSION="v0.40.1"
for i in 1 2 3; do
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o /tmp/nvm-install.sh && break
  echo "NVM download attempt $i failed, retrying in 5s..."
  sleep 5
done
bash /tmp/nvm-install.sh
rm -f /tmp/nvm-install.sh

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

nvm install 22.22.0
nvm use 22.22.0
nvm alias default 22.22.0

npm config set registry https://registry.npmjs.org/
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.3.24}"
ARCH=$(uname -m)
IGNORE_FLAG=""
if [ "$ARCH" = "aarch64" ] && [ "$OPENCLAW_VERSION" = "2026.3.24" ]; then
  IGNORE_FLAG="--ignore-scripts"
fi
npm install -g openclaw@$OPENCLAW_VERSION --timeout=300000 $IGNORE_FLAG || {
  npm cache clean --force
  npm install -g openclaw@$OPENCLAW_VERSION --timeout=300000 $IGNORE_FLAG
}

grep -q 'NVM_DIR' ~/.bashrc || {
  echo 'export NVM_DIR="$HOME/.nvm"' >> ~/.bashrc
  echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' >> ~/.bashrc
}
UBUNTU_SCRIPT

OPENCLAW_MJS=$(find /home/ubuntu/.nvm -path "*/node_modules/openclaw/openclaw.mjs" 2>/dev/null | head -1)
NODE_BIN=$(find /home/ubuntu/.nvm -name node -type f 2>/dev/null | head -1)
[ -z "$OPENCLAW_MJS" ] || [ -z "$NODE_BIN" ] && echo "FATAL: openclaw not found" && exit 1
printf '#!/bin/bash\nexec %s %s "$@"\n' "$NODE_BIN" "$OPENCLAW_MJS" > /usr/local/bin/openclaw
chmod +x /usr/local/bin/openclaw
/usr/local/bin/openclaw --version 2>/dev/null || { echo "FATAL: openclaw wrapper cannot execute"; exit 1; }

# ---- AWS config ----
echo "[6/9] Configuring AWS..."
sudo -u ubuntu mkdir -p /home/ubuntu/.aws
sudo -u ubuntu bash -c "printf '[default]\nregion = %s\noutput = json\n' \"$AWS_REGION\" > /home/ubuntu/.aws/config"
chown -R ubuntu:ubuntu /home/ubuntu/.aws
chmod 600 /home/ubuntu/.aws/config

# ---- Environment variables ----
echo "[7/9] Configuring environment variables..."
{
  echo "export AWS_REGION=$AWS_REGION"
  echo "export AWS_DEFAULT_REGION=$AWS_REGION"
  echo "export AWS_PROFILE=default"
  echo "export OPENCLAW_MODEL=$OPENCLAW_MODEL"
  echo "export OPENCLAW_USE_BEDROCK=true"
  echo "export OPENCLAW_STATE_DIR=/data/openclaw"
} >> /home/ubuntu/.bashrc
echo "export OPENCLAW_STATE_DIR=/data/openclaw" >> /home/ubuntu/.profile
chown ubuntu:ubuntu /home/ubuntu/.profile

mkdir -p /home/ubuntu/.config/systemd/user
chown -R ubuntu:ubuntu /home/ubuntu/.config
sudo -u ubuntu mkdir -p /home/ubuntu/.config/environment.d
sudo -u ubuntu bash -c "{ echo AWS_REGION=$AWS_REGION; echo AWS_DEFAULT_REGION=$AWS_REGION; echo AWS_PROFILE=default; } > /home/ubuntu/.config/environment.d/aws.conf"

loginctl enable-linger ubuntu
systemctl start user@1000.service

# ---- Configure OpenClaw ----
echo "[8/9] Configuring OpenClaw..."
sudo -u ubuntu mkdir -p "$STATE_DIR"
sudo -u ubuntu bash -c "printf 'AWS_PROFILE=default\nAWS_REGION=$AWS_REGION\nAWS_DEFAULT_REGION=$AWS_REGION\n' > $STATE_DIR/.env"

GATEWAY_TOKEN=$(openssl rand -hex 24)

if [ "$OPENCLAW_VERSION" = "2026.3.24" ]; then
  cp /opt/openclaw/openclaw-config-legacy.json "$STATE_DIR/openclaw.json"
  sed -i "s/REGION_PLACEHOLDER/$AWS_REGION/g" "$STATE_DIR/openclaw.json"
else
  cp /opt/openclaw/openclaw-config-modern.json "$STATE_DIR/openclaw.json"
fi
chown ubuntu:ubuntu "$STATE_DIR/openclaw.json"
sed -i "s/GATEWAY_TOKEN_PLACEHOLDER/$GATEWAY_TOKEN/g" "$STATE_DIR/openclaw.json"
sed -i "s|MODEL_ID_PLACEHOLDER|$OPENCLAW_MODEL|g" "$STATE_DIR/openclaw.json"

# ---- Start gateway ----
for i in $(seq 1 15); do
  [ -S /run/user/1000/bus ] && break
  echo "Waiting for user session... $i/15"; sleep 2
done

sudo -H -u ubuntu XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus OPENCLAW_STATE_DIR="$STATE_DIR" bash -c '
export HOME=/home/ubuntu
export OPENCLAW_STATE_DIR=$OPENCLAW_STATE_DIR
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
openclaw gateway install || echo "Gateway install failed"
systemctl --user start openclaw-gateway.service || { openclaw gateway & } || echo "Gateway start failed"
'

echo "Waiting for OpenClaw daemon..."
for i in $(seq 1 30); do
  ss -tlnp 2>/dev/null | grep -q ':18789' && echo "OpenClaw daemon is up on port 18789" && break
  echo "Attempt $i/30: waiting..."; sleep 2
done

if ! ss -tlnp 2>/dev/null | grep -q ':18789'; then
  echo "WARNING: Gateway did not start, trying fallback..."
  sudo -H -u ubuntu XDG_RUNTIME_DIR=/run/user/1000 bash -c '
  export HOME=/home/ubuntu
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  systemctl --user restart openclaw-gateway.service || openclaw gateway &
  '
  sleep 5
fi

# ---- Enable messaging channels ----
echo "[8.5/9] Enabling messaging channels..."
sudo -H -u ubuntu bash -c '
export HOME=/home/ubuntu
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
openclaw plugins enable whatsapp || echo "WhatsApp plugin enable failed"
openclaw plugins enable telegram || echo "Telegram plugin enable failed"
openclaw plugins enable discord  || echo "Discord plugin enable failed"
openclaw plugins enable slack    || echo "Slack plugin enable failed"
npm install -g openclaw-feishu@latest --timeout=60000 2>/dev/null || echo "Feishu plugin install skipped"
npm install -g openclaw-wechat@latest  --timeout=60000 2>/dev/null || echo "WeChat plugin install skipped"
'

cp /opt/openclaw/SOUL.md "$STATE_DIR/SOUL.md"
chown ubuntu:ubuntu "$STATE_DIR/SOUL.md"

# ---- Save token to SSM (never written to disk) ----
aws ssm put-parameter \
  --name "/openclaw/$STACK_NAME/gateway-token" \
  --value "$GATEWAY_TOKEN" \
  --type "SecureString" \
  --region "$AWS_REGION" \
  --overwrite || echo "Failed to save token to SSM"
unset GATEWAY_TOKEN

echo "$INSTANCE_ID" > "$STATE_DIR/instance_id.txt"
echo "$AWS_REGION"  > "$STATE_DIR/region.txt"
cp /opt/openclaw/ssm-portforward.sh /home/ubuntu/ssm-portforward.sh
chown ubuntu:ubuntu /home/ubuntu/ssm-portforward.sh

# ---- Health check cron ----
cat > /opt/openclaw/health-check.sh << 'HEALTHCHECK'
#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
LOG="/var/log/openclaw-health.log"
MAX_LOG_SIZE=1048576
[ -f "$LOG" ] && [ $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ] && mv "$LOG" "$LOG.old"
if ! ss -tlnp 2>/dev/null | grep -q ':18789'; then
  echo "$(date) UNHEALTHY: restarting gateway" >> $LOG
  sudo -H -u ubuntu bash -c "export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user restart openclaw-gateway.service" 2>>$LOG
  sleep 10
  ss -tlnp 2>/dev/null | grep -q ':18789' && echo "$(date) RECOVERED" >> $LOG || echo "$(date) CRITICAL: failed to restart" >> $LOG
  exit 0
fi
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://127.0.0.1:18789/ 2>/dev/null || echo "000")
if [ "$HTTP_STATUS" = "000" ]; then
  echo "$(date) UNHEALTHY: HTTP not responding, restarting" >> $LOG
  sudo -H -u ubuntu bash -c "export XDG_RUNTIME_DIR=/run/user/1000; systemctl --user restart openclaw-gateway.service" 2>>$LOG
fi
HEALTHCHECK
chmod +x /opt/openclaw/health-check.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/openclaw/health-check.sh") | crontab -

# ---- CloudWatch Agent (conditional) ----
if [ "$ENABLE_MONITORING" = "true" ]; then
  echo "[post] Installing CloudWatch Agent..."
  CW_ARCH=$(uname -m)
  if [ "$CW_ARCH" = "aarch64" ]; then
    curl -sO "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb"
  else
    curl -sO "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb"
  fi
  dpkg -i -E amazon-cloudwatch-agent.deb || true
  rm -f amazon-cloudwatch-agent.deb
  cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "metrics": {
    "namespace": "OpenClaw",
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"],  "metrics_collection_interval": 300 },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/","/data"], "metrics_collection_interval": 300 },
      "swap": { "measurement": ["swap_used_percent"], "metrics_collection_interval": 300 }
    },
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/openclaw-setup.log",  "log_group_name": "/openclaw/setup",  "log_stream_name": "{instance_id}", "retention_in_days": 30 },
          { "file_path": "/var/log/openclaw-health.log", "log_group_name": "/openclaw/health", "log_stream_name": "{instance_id}", "retention_in_days": 14 }
        ]
      }
    }
  }
}
CWCONFIG
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json || echo "CloudWatch Agent config failed"
fi

# ---- Systemd memory limits ----
sudo -u ubuntu mkdir -p /home/ubuntu/.config/systemd/user/openclaw-gateway.service.d
cat > /home/ubuntu/.config/systemd/user/openclaw-gateway.service.d/memory-limit.conf << 'MEMLIMIT'
[Service]
MemoryMax=80%
MemoryHigh=70%
MEMLIMIT
chown -R ubuntu:ubuntu /home/ubuntu/.config/systemd/user/openclaw-gateway.service.d
sudo -H -u ubuntu XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus bash -c 'systemctl --user daemon-reload'

# ---- Log rotation ----
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/openclaw.conf << 'JOURNALD_CONF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=7day
JOURNALD_CONF
systemctl restart systemd-journald

# ---- Unattended upgrades ----
apt-get install -y unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTO_UPGRADES

# ---- openclaw doctor ----
sudo -H -u ubuntu XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus bash -c '
export HOME=/home/ubuntu
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
openclaw doctor --fix 2>&1 || echo "openclaw doctor completed with warnings"
'

echo "[9/9] Setup complete: $(date)"
echo "SUCCESS" > "$STATE_DIR/setup_status.txt"
echo "Setup completed: $(date)" >> "$STATE_DIR/setup_status.txt"
echo "=========================================="
echo "OpenClaw installation complete!"
echo "=========================================="
