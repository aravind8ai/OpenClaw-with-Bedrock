# OpenClaw on AWS with Bedrock

> Your own AI assistant on AWS — connects to WhatsApp, Telegram, Discord, Slack. Powered by Amazon Bedrock. No API keys. Deployed via Terraform + GitHub Actions. From ~$30/month.

[![License](https://img.shields.io/badge/License-MIT--0-yellow?style=for-the-badge)](https://opensource.org/licenses/MIT)
[![Amazon Bedrock](https://img.shields.io/badge/Powered_by-Amazon_Bedrock-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white)](https://aws.amazon.com/bedrock/)
[![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)](https://www.terraform.io/)

---

## What This Is

[OpenClaw](https://github.com/openclaw/openclaw) is an open-source AI assistant that runs on your own infrastructure, connects to your messaging apps, and actually does things: browses the web, runs commands, manages files, schedules tasks.

This project deploys OpenClaw on AWS using Terraform, with a full CI/CD pipeline via GitHub Actions. You get:

- **Amazon Bedrock** for model inference — IAM auth, no API keys to manage
- **Graviton ARM instances** — 20–40% cheaper than x86
- **SSM Session Manager** — secure shell access without opening any ports
- **VPC Endpoints** — Bedrock and SSM traffic stays on the AWS private network
- **CloudWatch** — auto-recovery, health alarms, log shipping

---

## Architecture

```
You (WhatsApp / Telegram / Discord / Slack)
  │
  ▼
┌──────────────────────────────────────────────────────────┐
│  AWS VPC (10.0.0.0/16)                                   │
│                                                          │
│  ┌─────────────────────┐      ┌──────────────────────┐  │
│  │  EC2 (OpenClaw)     │─IAM─▶│  Amazon Bedrock      │  │
│  │  Ubuntu 24.04       │      │  Nova / Claude / etc  │  │
│  │  Graviton ARM       │      └──────────────────────┘  │
│  │  Port 18789 (local) │                                 │
│  └─────────────────────┘      ┌──────────────────────┐  │
│           │                   │  SSM Parameter Store  │  │
│           │  (gateway token)  │  /openclaw/<stack>/   │  │
│           └──────────────────▶│  gateway-token        │  │
│                               └──────────────────────┘  │
│                                                          │
│  VPC Endpoints (optional)                                │
│  bedrock-runtime · bedrock-mantle · ssm                  │
│  ssmmessages · ec2messages                               │
│                                                          │
│  S3 (setup script) · EBS x2 (root + data, 30GB gp3)     │
│  CloudWatch Alarms (auto-recovery + reboot)              │
└──────────────────────────────────────────────────────────┘
  │
  ▼
You (receive response in your messaging app)
```

### Request Flow

1. You send a message on WhatsApp, Telegram, Discord, or Slack
2. OpenClaw gateway (running on EC2, port 18789) receives it
3. Gateway calls Amazon Bedrock via IAM role — no API keys
4. Bedrock returns the model response
5. Gateway sends the reply back to your messaging platform

---

## AWS Services Used

| Service | Purpose |
|---------|---------|
| **EC2** | Runs the OpenClaw gateway process (Ubuntu 24.04, Graviton ARM) |
| **Amazon Bedrock** | LLM inference — Nova, Claude, DeepSeek, Llama, Kimi |
| **IAM** | Instance role with least-privilege Bedrock + SSM + CloudWatch access |
| **VPC** | Isolated network with public + private subnets across 2 AZs |
| **VPC Endpoints** | Private connectivity to Bedrock, SSM, EC2 Messages (optional) |
| **SSM Session Manager** | Secure shell access and port forwarding — no open ports |
| **SSM Parameter Store** | Stores the gateway token as a SecureString |
| **S3** | Hosts the EC2 setup script (exceeds 16KB user_data limit) |
| **EBS** | Root volume (30GB gp3) + separate data volume (30GB gp3, encrypted) |
| **CloudWatch** | Metrics, log groups, auto-recovery and reboot alarms |
| **ECR** | Container registry for action-lambda and Streamlit Docker images |
| **Lambda** | Action handler (amd64) + OpenSearch index creator |
| **OpenSearch Serverless** | Vector store for the Bedrock Knowledge Base |
| **Bedrock Agent** | Orchestrates tool use and knowledge base retrieval |
| **ECS** | Runs the Streamlit frontend container (arm64) |
| **Glue** | Crawler for Text2SQL table discovery |
| **Athena** | SQL query execution against crawled data |
| **KMS** | Encryption key for agent assets |

---

## CI/CD Pipeline

The GitHub Actions pipeline in `.github/workflows/` handles the full lifecycle.

### Workflows

| File | Trigger | What it does |
|------|---------|-------------|
| `deploy.yml` | Push to `main`, PR, manual | Full deploy: plan on PR, phased apply + agent bootstrap on merge |
| `terraform-plan.yml` | PR to `main` | Plan only, posts diff as PR comment |
| `terraform-apply.yml` | Push to `main`, manual | Applies terraform, shows outputs |
| `terraform-destroy.yml` | Manual only | Destroys stack (requires typing `destroy` to confirm) |

### Deploy Flow (`deploy.yml`)

```
PR opened
  └─▶ terraform-plan job
        ├── AWS OIDC auth
        ├── terraform init (S3 backend + DynamoDB lock)
        ├── terraform validate
        ├── terraform plan
        └── post plan diff as PR comment

Merge to main
  └─▶ terraform-apply job
        ├── Phase 1: ECR repos, OpenSearch, KMS, S3, IAM, Lambda layers, create-index Lambda
        ├── Phase 2: Build & push Docker images to ECR (action-lambda amd64, streamlit arm64)
        ├── Phase 3: Invoke create-index Lambda → creates OpenSearch index
        ├── Phase 4: Apply remaining infra (Bedrock Agent, KB, ECS, action Lambda, etc.)
        └── Export outputs (agent_id, kb_id, ecs_cluster, ecs_service, invoke_lambda)
              │
              ▼
        bootstrap-agents job (needs: terraform-apply)
              ├── Run Glue crawler → wait for READY
              ├── Sync Bedrock Knowledge Base data source → wait for COMPLETE
              └── Prepare Bedrock Agent → create/update alias
```

### Required GitHub Secrets & Variables

| Name | Type | Description |
|------|------|-------------|
| `AWS_ROLE_ARN` | Secret | IAM role ARN for OIDC authentication |
| `TF_STATE_BUCKET` | Secret | S3 bucket for Terraform remote state |
| `TF_LOCK_TABLE` | Secret | DynamoDB table for state locking |
| `AWS_ACCOUNT_ID` | Secret | AWS account ID (used to name the create-index Lambda) |
| `AWS_REGION` | Variable | Deployment region (default: `us-east-1`) |
| `STACK_NAME` | Variable | Resource name prefix (default: `chatbot-stack`) |
| `OPENCLAW_MODEL` | Variable | Bedrock model ID (default: `global.amazon.nova-2-lite-v1:0`) |
| `INSTANCE_TYPE` | Variable | EC2 instance type (default: `t2.micro`) |
| `CREATE_VPC_ENDPOINTS` | Variable | `true` / `false` (default: `true`) |
| `ENABLE_MONITORING` | Variable | `true` / `false` (default: `true`) |
| `BEDROCK_AGENT_ALIAS` | Variable | Agent alias name (default: `Chatbot_Agent`) |

---

## Deploying

### Option 1 — GitHub Actions (recommended)

1. Fork this repo
2. Set the secrets and variables above in your repo settings
3. Push to `main` — the pipeline deploys automatically

To destroy: go to Actions → Terraform Destroy → Run workflow → type `destroy`

### Option 2 — Terraform CLI

```bash
cd terraform

# Copy and edit variables
cp terraform.tfvars.example terraform.tfvars

terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="key=openclaw/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=YOUR_LOCK_TABLE"

terraform plan
terraform apply
```

### Option 3 — CloudFormation (one-click)

| Region | Launch |
|--------|--------|
| US West (Oregon) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/create/review?stackName=openclaw-bedrock&templateURL=https://sharefile-jiade.s3.cn-northwest-1.amazonaws.com.cn/clawdbot-bedrock.yaml) |
| US East (Virginia) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?stackName=openclaw-bedrock&templateURL=https://sharefile-jiade.s3.cn-northwest-1.amazonaws.com.cn/clawdbot-bedrock.yaml) |
| EU (Ireland) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=eu-west-1#/stacks/create/review?stackName=openclaw-bedrock&templateURL=https://sharefile-jiade.s3.cn-northwest-1.amazonaws.com.cn/clawdbot-bedrock.yaml) |
| Asia Pacific (Tokyo) | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=ap-northeast-1#/stacks/create/review?stackName=openclaw-bedrock&templateURL=https://sharefile-jiade.s3.cn-northwest-1.amazonaws.com.cn/clawdbot-bedrock.yaml) |

### Deploy with Kiro AI (guided)

Open this repo as a workspace in [Kiro](https://kiro.dev/) and say "help me deploy OpenClaw" — it walks you through every step conversationally.

---

## Accessing the Web UI

After deployment, access is via SSM port forwarding — no public ports are opened.

```bash
# 1. Install SSM Session Manager Plugin (one-time)
#    https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

# 2. Get the instance ID from Terraform output or AWS console
INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id)

# 3. Start port forwarding (keep this terminal open)
aws ssm start-session \
  --target $INSTANCE_ID \
  --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["18789"],"localPortNumber":["18789"]}'

# 4. In a second terminal, retrieve the gateway token
TOKEN=$(aws ssm get-parameter \
  --name /openclaw/chatbot-stack/gateway-token \
  --with-decryption \
  --query Parameter.Value \
  --output text \
  --region us-east-1)

# 5. Open in browser
echo "http://localhost:18789/?token=$TOKEN"
```

---

## Connecting Messaging Platforms

Once the Web UI is open, go to Channels → Add Channel:

| Platform | How to connect | Docs |
|----------|---------------|------|
| WhatsApp | Scan QR code from your phone | [docs](https://docs.openclaw.ai/channels/whatsapp) |
| Telegram | Create bot via @BotFather, paste token | [docs](https://docs.openclaw.ai/channels/telegram) |
| Discord | Create app in Developer Portal, paste bot token | [docs](https://docs.openclaw.ai/channels/discord) |
| Slack | Create app at api.slack.com, install to workspace | [docs](https://docs.openclaw.ai/channels/slack) |
| Microsoft Teams | Requires Azure Bot setup | [docs](https://docs.openclaw.ai/channels/msteams) |

---

## Using OpenClaw

Once connected to a messaging platform, just send messages:

```
What's the weather in Tokyo?
Summarize this PDF [attach file]
Remind me every day at 9am to check emails
Search the web for AWS Bedrock pricing
```

| Command | What it does |
|---------|-------------|
| `/status` | Show model, tokens used, estimated cost |
| `/new` | Start a fresh conversation |
| `/think high` | Enable deep reasoning mode |
| `/help` | List all available commands |

Voice messages work on WhatsApp and Telegram — OpenClaw transcribes and responds.

---

## Models

| Model | Input / Output per 1M tokens | Best for |
|-------|------------------------------|---------|
| Nova 2 Lite (default) | $0.30 / $2.50 | Everyday tasks, 90% cheaper than Claude |
| Nova Pro | $0.80 / $3.20 | Balanced, multimodal |
| Kimi K2.5 | $0.60 / $3.00 | Multimodal agentic, 262K context |
| Claude Haiku 4.5 | $1.00 / $5.00 | Fast and efficient |
| Claude Sonnet 4 | $3.00 / $15.00 | Reliable coding and analysis |
| Claude Sonnet 4.5 | $3.00 / $15.00 | Complex reasoning, coding |
| Claude Opus 4.5 | $15.00 / $75.00 | Deep analysis, extended thinking |
| Claude Opus 4.6 | $15.00 / $75.00 | Most capable |
| DeepSeek R1 | $0.55 / $2.19 | Open-source reasoning |
| Llama 3.3 70B | — | Open-source alternative |

Switch models by updating the `OPENCLAW_MODEL` variable and re-running the pipeline.

---

## Cost

| Component | Monthly | Notes |
|-----------|---------|-------|
| EC2 c7g.large | ~$52 | Default instance |
| EBS (30GB gp3 x2) | ~$4.80 | Root + data volumes |
| VPC Endpoints | ~$29 | 5 endpoints — disable to save |
| CloudWatch | ~$4 | Disable to save |
| Bedrock (Nova 2 Lite) | $5–8 | ~100 conversations/day |
| S3 + ECR | <$1 | Setup script + images |
| Total (all on) | ~$95–99 | |
| Total (VPCe + CW off) | ~$62–66 | |

---

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-west-2` | Deployment region |
| `stack_name` | `openclaw-bedrock` | Prefix for all resource names |
| `openclaw_model` | Nova 2 Lite | Bedrock model ID |
| `openclaw_version` | `2026.3.24` | OpenClaw version to install |
| `instance_type` | `t2.micro` | EC2 instance type (free tier eligible; upgrade for production) |
| `key_pair_name` | _(empty)_ | EC2 key pair for emergency SSH |
| `allowed_ssh_cidr` | _(empty)_ | CIDR for SSH — leave empty to disable |
| `create_vpc_endpoints` | `true` | Private Bedrock + SSM networking |
| `enable_sandbox` | `true` | Docker for sandboxed code execution |
| `enable_monitoring` | `true` | CloudWatch alarms + auto-recovery |
| `enable_data_protection` | `false` | Retain data EBS on destroy |

---

## Security

| Layer | What it does |
|-------|-------------|
| IAM Roles | No API keys — automatic credential rotation via instance profile |
| IMDSv2 enforced | Instance metadata requires secure token, no v1 fallback |
| SSM Session Manager | No public ports, all access via encrypted SSM tunnel |
| VPC Endpoints | Bedrock and SSM traffic never leaves the AWS network |
| SSM Parameter Store | Gateway token stored as SecureString, never written to disk |
| Security Group | No inbound rules by default — SSH only if key pair + CIDR both set |
| EBS encryption | Both volumes encrypted at rest (AES-256) |
| S3 bucket | Setup script bucket is private, server-side encrypted, public access blocked |
| Docker Sandbox | Isolates code execution in group chats |

---

## Reliability

| Layer | What it does | Frequency |
|-------|-------------|----------|
| Port health check | Detects dead gateway, auto-restarts | Every 5 min |
| HTTP health check | Detects hung gateway, auto-restarts | Every 5 min |
| Channel monitoring | Detects disconnected platforms, auto-restarts | Every 30 min |
| systemd Restart=always | Auto-restarts on crash | Immediate |
| 2GB swap | Prevents OOM kills on low-memory instances | Always on |
| CloudWatch auto-recovery | Recovers instance on hardware failure | On alarm |
| CloudWatch reboot alarm | Reboots on instance status check failure | On alarm |

---

## Troubleshooting

[TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Contributing

[GitHub Issues](https://github.com/aws-samples/sample-OpenClaw-on-AWS-with-Bedrock/issues)

## Resources

- [OpenClaw Docs](https://docs.openclaw.ai/) · [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [Amazon Bedrock Docs](https://docs.aws.amazon.com/bedrock/) · [SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest)

---

**Built with Kiro** 🦞
