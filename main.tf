# Remote dev container running Claude Code on AWS EC2.
#
# Usage:
#   terraform init
#   terraform apply
#
# Bootstrapping takes ~3-5 min after apply; check /var/log/cloud-init-output.log.
#
# Changes roll out with `terraform apply` alone: the provisioning script in
# user_data runs on every boot (not just the first), and changing it makes
# Terraform stop and start the instance. Put tools in the Dockerfile below
# rather than installing them by hand. Everything under /srv (workspace and
# Claude's home) lives on the root volume, so the instance is protected from
# replacement (see lifecycle below).
#
# Shell access is via AWS Systems Manager Session Manager: no open ports, no
# SSH keys, no IP allowlist. Open `terraform output -raw session_manager_url`
# in any browser (works on a phone), signed in to the AWS console.
# SSH is optional: pass -var="allowed_ssh_cidr=1.2.3.4/32" to enable it.
#
# One-time setup in a Session Manager shell (Remote Control needs a claude.ai
# login, NOT an API key):
#   claude-dev      # run /login, pick claude.ai, then /exit
#   claude-attach   # answer "Enable Remote Control?" (y) and
#                   # "Trust /workspace?" (y), then just close the tab;
#                   # the tmux session keeps running
#
# After that, every time the instance boots, `claude remote-control` starts on
# its own and the session appears in the Claude app's Code tab as "claude-dev".
#
# The instance stops itself after var.idle_stop_minutes of inactivity
# (idle-stop.sh). Start it again from your phone with the power URL:
#   terraform output -raw power_links   # bookmark the ?action=start one

terraform {
  required_version = ">= 1.6" # import blocks with expressions
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
  default     = null
  description = "Optional: CIDR allowed to SSH in, e.g. 203.0.113.4/32. Leave null for Session Manager only."
}

variable "name" {
  type    = string
  default = "claude-dev"
}

variable "idle_stop_minutes" {
  type        = number
  default     = 30
  description = "Stop the instance after this many minutes with no Claude activity, open shell or CPU load."
}

variable "swap_size_gb" {
  type        = number
  default     = 4
  description = "Swap file size; running out of RAM slows things down instead of killing a session."
}

variable "sandbox_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "sandbox_instance_types" {
  type        = list(string)
  default     = ["t3.micro", "t3.small", "t3.medium", "t4g.micro", "t4g.small", "t4g.medium"]
  description = "Instance types Claude may launch in the sandbox (cost cap)."
}

variable "sandbox_max_volume_gb" {
  type    = number
  default = 50
}

variable "sandbox_account_email" {
  type        = string
  description = "Root email for the sandbox AWS account; must be unique across AWS (a Gmail +suffix works). Set it in terraform.tfvars, which is gitignored."
}

variable "sandbox_monthly_budget_usd" {
  type        = number
  default     = 25
  description = "Monthly spend cap for the sandbox account. At 100% of actual spend, a policy blocking new resources is attached automatically."
}

# ---------- Networking (default VPC) ----------

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "dev" {
  name        = "${var.name}-sg"
  description = "Claude Code dev box (egress only unless SSH enabled)"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.allowed_ssh_cidr == null ? [] : [var.allowed_ssh_cidr]
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
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
  count      = var.allowed_ssh_cidr == null ? 0 : 1
  key_name   = "${var.name}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# ---------- Session Manager access ----------

resource "aws_iam_role" "dev" {
  name = "${var.name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dev_ssm" {
  role       = aws_iam_role.dev.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "dev" {
  name = "${var.name}-instance"
  role = aws_iam_role.dev.name
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
  key_name               = one(aws_key_pair.dev[*].key_name)
  vpc_security_group_ids = [aws_security_group.dev.id]
  iam_instance_profile   = aws_iam_instance_profile.dev.name

  # idle-stop runs `shutdown -h now`; make sure that stops (not terminates).
  instance_initiated_shutdown_behavior = "stop"

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 only
    # 2 lets the container (one network hop further) use the instance role;
    # Claude relies on that for the access in aws_iam_role_policy.dev_claude.
    http_put_response_hop_limit = 2
  }

  lifecycle {
    # The root volume holds /srv, so replacing the instance loses everything.
    # New Ubuntu AMIs are ignored, and any other change that would force a
    # replacement (e.g. toggling SSH, which changes key_name) fails the plan.
    # Remove prevent_destroy on purpose if you really want a fresh instance.
    ignore_changes  = [ami]
    prevent_destroy = true
  }

  # A user_data change stops and starts the instance (no replacement), and the
  # cloud-config part below re-runs the script on every boot. The script must
  # stay idempotent.
  user_data_replace_on_change = false
  user_data                   = <<-EOT
    Content-Type: multipart/mixed; boundary="//"
    MIME-Version: 1.0

    --//
    Content-Type: text/cloud-config; charset="us-ascii"
    MIME-Version: 1.0
    Content-Transfer-Encoding: 7bit
    Content-Disposition: attachment; filename="cloud-config.txt"

    #cloud-config
    cloud_final_modules:
    - [scripts-user, always]

    --//
    Content-Type: text/x-shellscript; charset="us-ascii"
    MIME-Version: 1.0
    Content-Transfer-Encoding: 7bit
    Content-Disposition: attachment; filename="provision.sh"

    #!/bin/bash
    set -euxo pipefail

    # cloud-init keeps scripts from earlier user_data versions here and runs
    # them all on every boot; only this one should run from now on.
    find /var/lib/cloud/instance/scripts -maxdepth 1 -type f ! -name provision.sh -delete

    if ! command -v docker >/dev/null; then
      apt-get update
      apt-get install -y docker.io git
    fi
    systemctl enable --now docker
    usermod -aG docker ubuntu

    # --- Swap (recreated if swap_size_gb changes) ---
    if [ "$(stat -c %s /swapfile 2>/dev/null)" != "$((${var.swap_size_gb} * 1024 * 1024 * 1024))" ]; then
      swapoff /swapfile 2>/dev/null || true
      rm -f /swapfile
      fallocate -l ${var.swap_size_gb}G /swapfile
      chmod 600 /swapfile
      mkswap /swapfile
    fi
    swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile
    sysctl -w vm.swappiness=10 # use RAM first; swap is the safety net

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
          git curl ripgrep jq less vim sudo tmux python3 python3-pip unzip \
        && rm -rf /var/lib/apt/lists/*
    # GitHub CLI (login persists in /home/node/.config/gh)
    RUN mkdir -p -m 755 /etc/apt/keyrings \
        && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
             -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        && echo "deb [signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
             > /etc/apt/sources.list.d/github-cli.list \
        && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*
    # AWS CLI v2; credentials come from the instance role
    RUN curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscli.zip \
        && unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install && rm -rf /tmp/aws /tmp/awscli.zip
    ENV AWS_DEFAULT_REGION=${var.region}
    # Terraform, for sandbox deployments (see "Sandbox VPC" below)
    RUN curl -fsSL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip -o /tmp/tf.zip \
        && unzip -q /tmp/tf.zip terraform -d /usr/local/bin && rm /tmp/tf.zip
    # node owns the global install so Claude Code can auto-update itself
    RUN npm install -g @anthropic-ai/claude-code \
        && chown -R node:node /usr/local/lib/node_modules /usr/local/bin
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
    chown 1000:1000 /srv/workspace /srv/claude-home

    # Recreate the container only when the image changed, so a plain reboot
    # keeps anything installed inside it.
    if [ "$(docker inspect -f '{{.Image}}' claude-dev 2>/dev/null)" != "$(docker image inspect -f '{{.Id}}' claude-dev)" ]; then
      docker rm -f claude-dev 2>/dev/null || true
      docker run -d --name claude-dev --restart unless-stopped \
        -v /srv/workspace:/workspace \
        -v /srv/claude-home:/home/node \
        claude-dev
    fi
    # Drop images left behind by earlier builds (unused ones only).
    docker image prune -f

    # --- Convenience commands on the host (sudo: Session Manager logs in as
    # ssm-user, which is not in the docker group) ---
    cat > /usr/local/bin/claude-dev <<'EOF'
    #!/bin/bash
    exec sudo docker exec -it -w /workspace claude-dev claude "$@"
    EOF
    cat > /usr/local/bin/dev-shell <<'EOF'
    #!/bin/bash
    exec sudo docker exec -it -w /workspace claude-dev bash
    EOF
    cat > /usr/local/bin/claude-attach <<'EOF'
    #!/bin/bash
    exec sudo docker exec -it claude-dev tmux attach -t claude
    EOF
    chmod +x /usr/local/bin/claude-dev /usr/local/bin/dev-shell /usr/local/bin/claude-attach

    # --- Auto-stop when idle (see idle-stop.sh) ---
    echo '${base64encode(file("${path.module}/idle-stop.sh"))}' | base64 -d > /usr/local/bin/idle-stop
    chmod +x /usr/local/bin/idle-stop
    echo '*/5 * * * * root IDLE_MINUTES=${var.idle_stop_minutes} /usr/local/bin/idle-stop' > /etc/cron.d/idle-stop

    --//--
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
          # Browsers also fetch /favicon.ico; don't treat that as a call.
          if event.get("rawPath", "/") != "/":
              return reply(404, {"error": "not found"})
          headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
          qs = event.get("queryStringParameters") or {}
          supplied = headers.get("x-token") or qs.get("token") or ""
          action = qs.get("action", "status")
          authorized = hmac.compare_digest(supplied, TOKEN)
          # One JSON line per call in CloudWatch Logs (never the token).
          print(json.dumps({
              "action": action,
              "authorized": authorized,
              "source_ip": (event.get("requestContext") or {}).get("http", {}).get("sourceIp"),
          }))
          if not authorized:
              return reply(403, {"error": "forbidden"})

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

# Lambda created this log group on first run; Terraform adopts it (import is
# a no-op once it's in state) to set an expiry.
import {
  to = aws_cloudwatch_log_group.power
  id = "/aws/lambda/${var.name}-power"
}

resource "aws_cloudwatch_log_group" "power" {
  name              = "/aws/lambda/${var.name}-power"
  retention_in_days = 90
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

# ---------- Claude's own access ----------
# Lets Claude, from inside the container, run shell commands on this host as
# root (SSM Run Command) and read the power switch's logs. Anything running in
# the container gets the same access. Intended blast radius: this instance,
# plus read-only on its power logs, plus the sandbox VPC and sandbox account
# below. Changes to anything else in AWS go through `terraform apply` by a
# human (the role has no EC2/IAM/Lambda write access in this account).
#   aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
#     --parameters 'commands=["uptime"]'
#   aws logs filter-log-events --log-group-name /aws/lambda/claude-dev-power

data "aws_caller_identity" "current" {}

locals {
  ec2_arn             = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}"
  power_log_group_arn = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${aws_lambda_function.power.function_name}"
}

resource "aws_iam_role_policy" "dev_claude" {
  name = "claude-self-access"
  role = aws_iam_role.dev.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunShellOnThisInstance"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          aws_instance.dev.arn,
          "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid      = "RunShellOnSandboxInstances"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "${local.ec2_arn}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Sandbox" = var.name }
        }
      },
      {
        # Can't be scoped by resource, but needs the command ID, which only the
        # caller of SendCommand knows. (No List* here: that would show every
        # command in the account.)
        Sid      = "ReadOwnCommandResults"
        Effect   = "Allow"
        Action   = "ssm:GetCommandInvocation"
        Resource = "*"
      },
      {
        Sid    = "ReadPowerSwitchLogs"
        Effect = "Allow"
        Action = ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams"]
        Resource = [
          local.power_log_group_arn,
          "${local.power_log_group_arn}:*",
        ]
      },
      {
        # AmazonSSMManagedInstanceCore allows reading every Parameter Store
        # parameter in the account; Session Manager doesn't need that.
        Sid      = "NoAccountWideParameterReads"
        Effect   = "Deny"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "*"
      },
    ]
  })
}

# ---------- Sandbox VPC ----------
# A separate VPC where Claude deploys projects. Claude administers EC2 inside
# it (instances, security groups, subnets, routes, volumes) and nothing
# outside it. Two rules enforce that:
#   - new instances, security groups, subnets and route tables must be created
#     in this VPC (ec2:Vpc / the VPC's ARN);
#   - instances and volumes must carry the tag Sandbox = var.name at creation,
#     only sandbox-tagged resources can be changed or deleted, and that tag
#     can't be added to anything that doesn't already have it.
# The dev box lives in the default VPC without that tag, so it's out of reach.
# Project configs should set provider default_tags { Sandbox = "<var.name>" },
# launch into the sandbox subnets, and use the sandbox instance profile.
# Not covered yet: load balancers, RDS, ECS, Elastic IPs.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "sandbox" {
  cidr_block           = var.sandbox_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-sandbox", Sandbox = var.name }
}

resource "aws_internet_gateway" "sandbox" {
  vpc_id = aws_vpc.sandbox.id
  tags   = { Name = "${var.name}-sandbox", Sandbox = var.name }
}

resource "aws_subnet" "sandbox_public" {
  count                   = 2
  vpc_id                  = aws_vpc.sandbox.id
  cidr_block              = cidrsubnet(var.sandbox_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-sandbox-public-${count.index}", Sandbox = var.name }
}

resource "aws_route_table" "sandbox_public" {
  vpc_id = aws_vpc.sandbox.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sandbox.id
  }
  tags = { Name = "${var.name}-sandbox-public", Sandbox = var.name }
}

resource "aws_route_table_association" "sandbox_public" {
  count          = 2
  subnet_id      = aws_subnet.sandbox_public[count.index].id
  route_table_id = aws_route_table.sandbox_public.id
}

# Role for instances Claude launches: Session Manager / Run Command only.
resource "aws_iam_role" "sandbox_instance" {
  name = "${var.name}-sandbox-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sandbox_instance_ssm" {
  role       = aws_iam_role.sandbox_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "sandbox_instance_no_params" {
  name = "no-account-wide-parameter-reads"
  role = aws_iam_role.sandbox_instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Deny"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "sandbox_instance" {
  name = "${var.name}-sandbox-instance"
  role = aws_iam_role.sandbox_instance.name
}

resource "aws_iam_role_policy" "dev_sandbox_admin" {
  name = "sandbox-vpc-admin"
  role = aws_iam_role.dev.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadEc2"
        Effect   = "Allow"
        Action   = "ec2:Describe*"
        Resource = "*"
      },
      # --- Launching instances ---
      {
        Sid    = "LaunchIntoSandboxNetwork"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "${local.ec2_arn}:subnet/*",
          "${local.ec2_arn}:security-group/*",
          "${local.ec2_arn}:network-interface/*",
        ]
        Condition = { StringEquals = { "ec2:Vpc" = aws_vpc.sandbox.arn } }
      },
      {
        Sid      = "LaunchTaggedCappedInstances"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2_arn}:instance/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/Sandbox" = var.name
            "ec2:InstanceType"       = var.sandbox_instance_types
          }
        }
      },
      {
        Sid      = "LaunchCappedVolumes"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "${local.ec2_arn}:volume/*"
        Condition = {
          NumericLessThanEquals = { "ec2:VolumeSize" = var.sandbox_max_volume_gb }
        }
      },
      {
        Sid    = "LaunchFromAnyImage"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:aws:ec2:${var.region}::image/*",
          "arn:aws:ec2:${var.region}::snapshot/*",
          "${local.ec2_arn}:key-pair/*",
          "${local.ec2_arn}:launch-template/*",
        ]
      },
      {
        Sid      = "PassSandboxInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.sandbox_instance.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      # --- Tags: set at creation, then only on sandbox resources ---
      {
        Sid      = "TagOnCreate"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "${local.ec2_arn}:*/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = [
              "RunInstances", "CreateVolume", "CreateSecurityGroup",
              "CreateSubnet", "CreateRouteTable",
            ]
          }
        }
      },
      {
        Sid      = "RetagSandboxResources"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "${local.ec2_arn}:*/*"
        Condition = {
          StringEquals                   = { "ec2:ResourceTag/Sandbox" = var.name }
          "ForAllValues:StringNotEquals" = { "aws:TagKeys" = ["Sandbox"] }
        }
      },
      # --- Managing instances and volumes ---
      {
        Sid    = "ManageSandboxInstances"
        Effect = "Allow"
        Action = [
          "ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances",
          "ec2:TerminateInstances", "ec2:GetConsoleOutput",
          "ec2:AssociateIamInstanceProfile", "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:DisassociateIamInstanceProfile",
        ]
        Resource  = "${local.ec2_arn}:instance/*"
        Condition = { StringEquals = { "ec2:ResourceTag/Sandbox" = var.name } }
      },
      {
        Sid      = "ModifySandboxInstancesWithinCap"
        Effect   = "Allow"
        Action   = "ec2:ModifyInstanceAttribute"
        Resource = "${local.ec2_arn}:instance/*"
        Condition = {
          StringEquals         = { "ec2:ResourceTag/Sandbox" = var.name }
          StringEqualsIfExists = { "ec2:Attribute/InstanceType" = var.sandbox_instance_types }
        }
      },
      {
        Sid      = "CreateTaggedCappedVolumes"
        Effect   = "Allow"
        Action   = "ec2:CreateVolume"
        Resource = "${local.ec2_arn}:volume/*"
        Condition = {
          StringEquals          = { "aws:RequestTag/Sandbox" = var.name }
          NumericLessThanEquals = { "ec2:VolumeSize" = var.sandbox_max_volume_gb }
        }
      },
      {
        Sid    = "ManageSandboxVolumes"
        Effect = "Allow"
        Action = ["ec2:AttachVolume", "ec2:DetachVolume", "ec2:DeleteVolume"]
        Resource = [
          "${local.ec2_arn}:volume/*",
          "${local.ec2_arn}:instance/*",
        ]
        Condition = { StringEquals = { "ec2:ResourceTag/Sandbox" = var.name } }
      },
      # --- Security groups, subnets, routes inside the sandbox VPC ---
      {
        Sid    = "CreateNetworkingInSandboxVpc"
        Effect = "Allow"
        Action = ["ec2:CreateSecurityGroup", "ec2:CreateSubnet", "ec2:CreateRouteTable"]
        Resource = [
          aws_vpc.sandbox.arn,
          "${local.ec2_arn}:security-group/*",
          "${local.ec2_arn}:subnet/*",
          "${local.ec2_arn}:route-table/*",
        ]
      },
      {
        Sid    = "ManageNetworkingInSandboxVpc"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
          "ec2:ModifySecurityGroupRules", "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
          "ec2:UpdateSecurityGroupRuleDescriptionsEgress", "ec2:DeleteSecurityGroup",
          "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
          "ec2:CreateRoute", "ec2:ReplaceRoute", "ec2:DeleteRoute", "ec2:DeleteRouteTable",
          "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        ]
        Resource = [
          "${local.ec2_arn}:security-group/*",
          "${local.ec2_arn}:subnet/*",
          "${local.ec2_arn}:route-table/*",
        ]
        Condition = { StringEquals = { "ec2:Vpc" = aws_vpc.sandbox.arn } }
      },
      {
        Sid      = "SecurityGroupRuleObjects"
        Effect   = "Allow"
        Action   = ["ec2:ModifySecurityGroupRules", "ec2:UpdateSecurityGroupRuleDescriptionsIngress", "ec2:UpdateSecurityGroupRuleDescriptionsEgress"]
        Resource = "${local.ec2_arn}:security-group-rule/*"
      },
    ]
  })
}

# ---------- Sandbox account ----------
# A separate AWS account that Claude fully administers: any service, any
# resource, its own IAM. The account boundary is the isolation, so nothing
# Claude does there can reach this account (the dev box, its role, the power
# Lambda or this Terraform). Claude gets in by assuming the account's
# OrganizationAccountAccessRole (AdministratorAccess), which Organizations
# creates and which trusts this account.
#
# Guardrails, as SCPs attached to the account (they bind every principal in
# it, including that admin role):
#   - always: can't leave the org, can't use regions other than var.region,
#     can't modify the admin role, can't buy reservations, savings plans,
#     domains or Marketplace subscriptions;
#   - at var.sandbox_monthly_budget_usd of actual spend, a budget action
#     attaches a policy that blocks everything except reading, stopping and
#     deleting. Running resources keep billing until they're stopped, and
#     billing data lags by hours, so this is a near-cap, not a hard one.
#
# This account becomes the organization's management account. If it already
# is one, import it first:
#   terraform import aws_organizations_organization.this <o-xxxxxxxxxx>
#
# On the dev box:  aws --profile sandbox sts get-caller-identity
# (the profile lives in ~/.aws/config; see the sandbox_cli_profile output)

resource "aws_organizations_organization" "this" {
  feature_set          = "ALL"
  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]
}

resource "aws_organizations_account" "sandbox" {
  name              = "${var.name}-sandbox"
  email             = var.sandbox_account_email
  close_on_deletion = true # removing it from Terraform closes the account
  depends_on        = [aws_organizations_organization.this]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name, iam_user_access_to_billing]
  }
}

locals {
  sandbox_account_id = aws_organizations_account.sandbox.id
  sandbox_admin_role = "arn:aws:iam::${local.sandbox_account_id}:role/OrganizationAccountAccessRole"
  # Not regional, so the region lock must not apply to them.
  global_services = [
    "iam:*", "sts:*", "organizations:*", "account:*", "route53:*", "route53domains:*",
    "cloudfront:*", "waf:*", "globalaccelerator:*", "budgets:*", "ce:*", "cur:*",
    "health:*", "support:*", "trustedadvisor:*", "pricing:*", "s3:GetBucketLocation",
    "s3:ListAllMyBuckets", "acm:*", "kms:*", "shield:*", "networkmanager:*",
  ]
}

resource "aws_organizations_policy" "sandbox_guardrails" {
  name        = "${var.name}-sandbox-guardrails"
  description = "Always on: stay in the org, stay in ${var.region}, leave the admin role alone"
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StayInOrg"
        Effect   = "Deny"
        Action   = ["organizations:LeaveOrganization", "account:CloseAccount", "account:PutAlternateContact", "account:DeleteAlternateContact"]
        Resource = "*"
      },
      {
        Sid       = "OneRegion"
        Effect    = "Deny"
        NotAction = local.global_services
        Resource  = "*"
        Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } }
      },
      {
        Sid    = "KeepAdminRole"
        Effect = "Deny"
        Action = [
          "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy",
          "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary",
          "iam:DeleteRolePermissionsBoundary", "iam:TagRole", "iam:UntagRole",
        ]
        Resource = "arn:aws:iam::*:role/OrganizationAccountAccessRole"
      },
      {
        # Up-front or long-term charges land before the budget can react.
        Sid    = "NoCommitments"
        Effect = "Deny"
        Action = [
          "ec2:PurchaseReservedInstancesOffering", "ec2:AcceptReservedInstancesExchangeQuote",
          "ec2:PurchaseHostReservation", "ec2:PurchaseScheduledInstances", "ec2:PurchaseCapacityBlock",
          "ec2:AllocateHosts", "ec2:CreateCapacityReservation",
          "rds:PurchaseReservedDBInstancesOffering", "elasticache:PurchaseReservedCacheNodesOffering",
          "redshift:PurchaseReservedNodeOffering", "es:PurchaseReservedInstanceOffering",
          "dynamodb:PurchaseReservedCapacityOfferings", "memorydb:PurchaseReservedNodesOffering",
          "savingsplans:CreateSavingsPlan",
          "route53domains:RegisterDomain", "route53domains:TransferDomain", "route53domains:RenewDomain",
          "aws-marketplace:Subscribe", "aws-marketplace:CreateAgreementRequest",
          "shield:CreateSubscription", # Shield Advanced is $3,000/month
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_organizations_policy_attachment" "sandbox_guardrails" {
  policy_id = aws_organizations_policy.sandbox_guardrails.id
  target_id = local.sandbox_account_id
}

# Attached by the budget action below when spend hits the cap. Detach it in
# the Organizations console to reset.
resource "aws_organizations_policy" "sandbox_over_budget" {
  name        = "${var.name}-sandbox-over-budget"
  description = "Budget exceeded: only reading, stopping and deleting are allowed"
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "OnlyReadStopDelete"
      Effect = "Deny"
      NotAction = [
        "sts:*", "iam:Get*", "iam:List*", "iam:Delete*", "iam:Detach*", "iam:Remove*",
        "ec2:Describe*", "ec2:Get*", "ec2:Stop*", "ec2:Terminate*", "ec2:Delete*",
        "ec2:Detach*", "ec2:Disassociate*", "ec2:Release*", "ec2:Revoke*",
        "autoscaling:Describe*", "autoscaling:Delete*", "autoscaling:UpdateAutoScalingGroup", "autoscaling:SetDesiredCapacity",
        "elasticloadbalancing:Describe*", "elasticloadbalancing:Delete*", "elasticloadbalancing:Deregister*",
        "rds:Describe*", "rds:List*", "rds:Stop*", "rds:Delete*",
        "ecs:Describe*", "ecs:List*", "ecs:UpdateService", "ecs:StopTask", "ecs:Delete*", "ecs:Deregister*",
        "eks:Describe*", "eks:List*", "eks:Delete*",
        "lambda:Get*", "lambda:List*", "lambda:Delete*", "lambda:PutFunctionConcurrency",
        "s3:Get*", "s3:List*", "s3:Delete*", "s3:PutLifecycleConfiguration",
        "dynamodb:Describe*", "dynamodb:List*", "dynamodb:DeleteTable",
        "elasticache:Describe*", "elasticache:Delete*",
        "cloudformation:Describe*", "cloudformation:List*", "cloudformation:Get*", "cloudformation:DeleteStack",
        "cloudfront:Get*", "cloudfront:List*", "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
        "logs:Describe*", "logs:Get*", "logs:FilterLogEvents", "logs:Delete*",
        "ssm:SendCommand", "ssm:GetCommandInvocation", "ssm:Describe*", "ssm:List*",
        "ecr:Describe*", "ecr:List*", "ecr:BatchDelete*", "ecr:DeleteRepository",
        "kms:Describe*", "kms:List*", "kms:ScheduleKeyDeletion", "kms:DisableKey",
        "route53:Get*", "route53:List*", "route53:Delete*", "route53:ChangeResourceRecordSets",
        "tag:Get*", "resource-groups:*", "ce:*", "budgets:View*", "pricing:*",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "budget_action" {
  name = "${var.name}-sandbox-budget-action"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "budgets.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "budget_action" {
  name = "attach-over-budget-scp"
  role = aws_iam_role.budget_action.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["organizations:AttachPolicy", "organizations:DetachPolicy"]
        Resource = [aws_organizations_policy.sandbox_over_budget.arn, aws_organizations_account.sandbox.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["organizations:DescribePolicy", "organizations:ListPolicies", "organizations:ListTargetsForPolicy"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_budgets_budget" "sandbox" {
  name         = "${var.name}-sandbox-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.sandbox_monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [local.sandbox_account_id]
  }

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", pct = 50 },
      { type = "ACTUAL", pct = 80 },
      { type = "FORECASTED", pct = 100 },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.pct
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = [var.sandbox_account_email]
    }
  }
}

resource "aws_budgets_budget_action" "sandbox_cap" {
  budget_name        = aws_budgets_budget.sandbox.name
  action_type        = "APPLY_SCP_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }

  definition {
    scp_action_definition {
      policy_id  = aws_organizations_policy.sandbox_over_budget.id
      target_ids = [local.sandbox_account_id]
    }
  }

  subscriber {
    address           = var.sandbox_account_email
    subscription_type = "EMAIL"
  }

  depends_on = [aws_iam_role_policy.budget_action]
}

# The dev box may become the sandbox admin, and may read costs (Cost Explorer
# shows the whole org; read-only) so it can watch spend itself.
resource "aws_iam_role_policy" "dev_sandbox_account" {
  name = "sandbox-account-admin"
  role = aws_iam_role.dev.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BecomeSandboxAdmin"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = local.sandbox_admin_role
      },
      {
        Sid      = "ReadCosts"
        Effect   = "Allow"
        Action   = ["ce:Get*", "ce:Describe*", "ce:List*", "budgets:ViewBudget", "budgets:DescribeBudgetAction*"]
        Resource = "*"
      },
    ]
  })
}

# ---------- Outputs ----------

output "public_ip" {
  value = aws_instance.dev.public_ip
}

output "instance_id" {
  value = aws_instance.dev.id
}

# Browser shell (sign in to the AWS console first); works from a phone.
output "session_manager_url" {
  value = "https://${var.region}.console.aws.amazon.com/systems-manager/session-manager/${aws_instance.dev.id}?region=${var.region}"
}

# From a laptop with the AWS CLI + Session Manager plugin installed.
output "connect_ssm" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.dev.id}"
}

output "connect_ssh" {
  value = var.allowed_ssh_cidr == null ? "SSH disabled (set allowed_ssh_cidr to enable)" : "ssh -t ubuntu@${aws_instance.dev.public_ip} claude-dev"
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

output "sandbox_account_id" {
  value = local.sandbox_account_id
}

# For ~/.aws/config on the dev box (Claude adds it after apply).
output "sandbox_cli_profile" {
  value = "[profile sandbox]\nrole_arn = ${local.sandbox_admin_role}\ncredential_source = Ec2InstanceMetadata\nregion = ${var.region}"
}
