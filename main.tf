# Remote dev container running Claude Code on AWS EC2.
#
# Usage:
#   terraform init
#   terraform apply -var="allowed_ssh_cidr=$(curl -s ifconfig.me)/32"
#
# Bootstrapping takes ~3-5 min after apply; check /var/log/cloud-init-output.log.
#
# One-time setup (Remote Control needs a claude.ai login, NOT an API key):
#   ssh -t ubuntu@<public_ip> claude-dev     # run /login, pick claude.ai, then /exit
#   ssh -t ubuntu@<public_ip> claude-attach  # answer "Enable Remote Control?" (y)
#                                            # and "Trust /workspace?" (y),
#                                            # then detach with Ctrl-b d
#
# After that, every time the instance boots, `claude remote-control` starts on
# its own and the session appears in the Claude app's Code tab as "claude-dev".

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---------- Variables ----------

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.medium" # 2 vCPU / 4 GB; bump for heavier builds
}

variable "volume_size_gb" {
  type    = number
  default = 40
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR allowed to SSH in, e.g. 203.0.113.4/32 (your IP)"
}

variable "name" {
  type    = string
  default = "claude-dev"
}

# ---------- Networking (default VPC) ----------

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "dev" {
  name        = "${var.name}-sg"
  description = "SSH access to Claude Code dev box"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-sg" }
}

resource "aws_key_pair" "dev" {
  key_name   = "${var.name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# ---------- AMI ----------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ---------- Instance ----------

resource "aws_instance" "dev" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.dev.key_name
  vpc_security_group_ids = [aws_security_group.dev.id]

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    apt-get update
    apt-get install -y docker.io git
    systemctl enable --now docker
    usermod -aG docker ubuntu

    # --- Dev container image ---
    mkdir -p /opt/claude-dev
    # Start script: keeps `claude remote-control` running in tmux, retrying if it
    # exits (not logged in yet, network outage >10 min, crash, etc.)
    cat > /opt/claude-dev/start.sh <<'EOF'
    #!/bin/bash
    tmux new-session -d -s claude -c /workspace \
      'while true; do
         claude remote-control --name claude-dev
         echo "remote-control exited; retrying in 15s"
         sleep 15
       done'
    exec sleep infinity
    EOF

    cat > /opt/claude-dev/Dockerfile <<'EOF'
    FROM node:22-bookworm
    RUN apt-get update && apt-get install -y \
          git curl ripgrep jq less vim sudo tmux python3 python3-pip \
        && rm -rf /var/lib/apt/lists/*
    RUN npm install -g @anthropic-ai/claude-code
    RUN echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node
    COPY start.sh /usr/local/bin/start.sh
    RUN chmod +x /usr/local/bin/start.sh
    ENV TERM=xterm-256color
    USER node
    WORKDIR /workspace
    CMD ["/usr/local/bin/start.sh"]
    EOF
    docker build -t claude-dev /opt/claude-dev

    # --- Persistent volumes (uid 1000 = node in container = ubuntu on host) ---
    mkdir -p /srv/workspace /srv/claude-home
    chown -R 1000:1000 /srv/workspace /srv/claude-home

    docker run -d --name claude-dev --restart unless-stopped \
      -v /srv/workspace:/workspace \
      -v /srv/claude-home:/home/node \
      claude-dev

    # --- Convenience commands on the host ---
    cat > /usr/local/bin/claude-dev <<'EOF'
    #!/bin/bash
    exec docker exec -it -w /workspace claude-dev claude "$@"
    EOF
    cat > /usr/local/bin/dev-shell <<'EOF'
    #!/bin/bash
    exec docker exec -it -w /workspace claude-dev bash
    EOF
    cat > /usr/local/bin/claude-attach <<'EOF'
    #!/bin/bash
    exec docker exec -it claude-dev tmux attach -t claude
    EOF
    chmod +x /usr/local/bin/claude-dev /usr/local/bin/dev-shell /usr/local/bin/claude-attach
  EOT

  tags = { Name = var.name }
}

# ---------- Pause / resume ----------
# terraform apply -var="instance_state=stopped"   # pause (disk kept)
# terraform apply -var="instance_state=running"   # resume

variable "instance_state" {
  type    = string
  default = "running"
  validation {
    condition     = contains(["running", "stopped"], var.instance_state)
    error_message = "instance_state must be \"running\" or \"stopped\"."
  }
}

resource "aws_ec2_instance_state" "dev" {
  instance_id = aws_instance.dev.id
  state       = var.instance_state
}

# ---------- Phone control: Lambda function URL ----------
# GET <power_url>?action=start|stop|status   with header  x-token: <token>
# (or &token=<token> in the query string for a browser bookmark)
# Returns JSON: {"action": ..., "state": ..., "public_ip": ...}
#
# Note: if you start/stop from your phone, the next `terraform apply` will set
# the instance back to var.instance_state.

resource "random_password" "power_token" {
  length  = 40
  special = false
}

data "archive_file" "power" {
  type        = "zip"
  output_path = "${path.module}/.build/power.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      import hmac, json, os
      import boto3

      ec2 = boto3.client("ec2")
      INSTANCE_ID = os.environ["INSTANCE_ID"]
      TOKEN = os.environ["TOKEN"]


      def reply(code, body):
          return {
              "statusCode": code,
              "headers": {"content-type": "application/json"},
              "body": json.dumps(body),
          }


      def handler(event, context):
          headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
          qs = event.get("queryStringParameters") or {}
          supplied = headers.get("x-token") or qs.get("token") or ""
          if not hmac.compare_digest(supplied, TOKEN):
              return reply(403, {"error": "forbidden"})

          action = qs.get("action", "status")
          if action == "start":
              ec2.start_instances(InstanceIds=[INSTANCE_ID])
          elif action == "stop":
              ec2.stop_instances(InstanceIds=[INSTANCE_ID])
          elif action != "status":
              return reply(400, {"error": "action must be start, stop or status"})

          inst = ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]
          return reply(200, {
              "action": action,
              "state": inst["State"]["Name"],
              "public_ip": inst.get("PublicIpAddress"),
          })
    PY
  }
}

resource "aws_iam_role" "power" {
  name = "${var.name}-power"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "power_logs" {
  role       = aws_iam_role.power.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "power_ec2" {
  name = "start-stop-dev-box"
  role = aws_iam_role.power.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = aws_instance.dev.arn
      },
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*" # Describe* doesn't support resource-level scoping
      }
    ]
  })
}

resource "aws_lambda_function" "power" {
  function_name    = "${var.name}-power"
  role             = aws_iam_role.power.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.power.output_path
  source_code_hash = data.archive_file.power.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      INSTANCE_ID = aws_instance.dev.id
      TOKEN       = random_password.power_token.result
    }
  }
}

resource "aws_lambda_function_url" "power" {
  function_name      = aws_lambda_function.power.function_name
  authorization_type = "NONE" # auth is the shared token, checked in code
}

# Public function URLs need both permissions (AWS requirement since Oct 2025).
resource "aws_lambda_permission" "power_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.power.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "power_invoke" {
  statement_id  = "AllowPublicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.power.function_name
  principal     = "*"
}

# ---------- Outputs ----------

output "public_ip" {
  value = aws_instance.dev.public_ip
}

output "connect_claude" {
  value = "ssh -t ubuntu@${aws_instance.dev.public_ip} claude-dev"
}

output "connect_shell" {
  value = "ssh -t ubuntu@${aws_instance.dev.public_ip} dev-shell"
}

output "power_url" {
  value = aws_lambda_function_url.power.function_url
}

output "power_token" {
  value     = random_password.power_token.result
  sensitive = true
}

# terraform output -raw power_links   → three ready-to-bookmark URLs
output "power_links" {
  sensitive = true
  value = join("\n", [
    for a in ["start", "stop", "status"] :
    "${aws_lambda_function_url.power.function_url}?action=${a}&token=${random_password.power_token.result}"
  ])
}
