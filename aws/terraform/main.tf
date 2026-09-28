terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" { 
  region = var.aws_region 
}

# --- 1. NETWORKING ---
resource "aws_vpc" "mc_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "Minecraft-VPC" }
}

resource "aws_internet_gateway" "mc_igw" { 
  vpc_id = aws_vpc.mc_vpc.id 
}

resource "aws_subnet" "mc_subnet" {
  vpc_id                  = aws_vpc.mc_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "mc_rt" {
  vpc_id = aws_vpc.mc_vpc.id
  route { 
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.mc_igw.id 
  }
}

resource "aws_route_table_association" "mc_rta" {
  subnet_id      = aws_subnet.mc_subnet.id
  route_table_id = aws_route_table.mc_rt.id
}

# --- 2. SECURITY GROUP ---
resource "aws_security_group" "mc_sg" {
  name   = "minecraft-ephemeral-sg"
  vpc_id = aws_vpc.mc_vpc.id
  
  ingress {
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 3. IAM (Allows EC2 to read/write to the S3 bucket) ---
resource "aws_iam_role" "mc_role" {
  name = "MinecraftEphemeralRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17", 
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.mc_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "s3_policy" {
  name = "MinecraftS3BackupPolicy"
  role = aws_iam_role.mc_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ 
      Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"], 
      Effect   = "Allow", 
      Resource = ["arn:aws:s3:::${var.s3_bucket}", "arn:aws:s3:::${var.s3_bucket}/*"] 
    }]
  })
}

resource "aws_iam_instance_profile" "mc_profile" {
  name = "MinecraftEphemeralProfile"
  role = aws_iam_role.mc_role.name
}

# --- 4. EC2 INSTANCE ---
data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"]
  
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

resource "aws_instance" "mc_server" {
  ami                    = data.aws_ami.ubuntu_arm.id
  instance_type          = "t4g.small"
  subnet_id              = aws_subnet.mc_subnet.id
  vpc_security_group_ids = [aws_security_group.mc_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.mc_profile.name

  # Automatically terminate instance when OS triggers poweroff
  instance_initiated_shutdown_behavior = "terminate"

  root_block_device {
    volume_type = "gp3"
    volume_size = 15
  }

  # Injects our bash script and variables dynamically
  user_data = templatefile("${path.module}/../scripts/server_bootstrap.sh", {
    s3_bucket            = var.s3_bucket
    project_id           = var.curseforge_project_id
    discord_webhook_url  = var.discord_webhook_url
    s3_enabled           = var.s3_enabled
    debug_script_content = file("${path.module}/../scripts/debug.sh")
  })

  tags = { Name = "Minecraft-Ephemeral-Server" }
}