# One-Time Infrastructure Setup

This guide covers the initial configuration required to run the ephemeral Minecraft server architecture. You only need to perform these steps once.

## 1. Prerequisites

You need the following tools installed on your local machine:

- **AWS CLI:** For authenticating with your AWS account.
- **Terraform:** For provisioning and destroying the cloud infrastructure.
- **Git:** To clone the repository.
- **jq:** (Optional) For parsing JSON in terminal if you want to inspect manifests locally.

## 2. AWS Account Configuration

Terraform requires administrator-level access to your AWS account to create the VPC, security groups, IAM roles, and EC2 instances.

1. Log into your AWS Console and navigate to **IAM (Identity and Access Management)**.
2. Create a new IAM User (e.g., `minecraft-admin`) and attach the **AdministratorAccess** policy.
3. Generate **Access Keys** for this user.
4. Open your local terminal and run:
   ```bash
   aws configure
   ```
5. Enter your `Access Key ID`, `Secret Access Key`, and set your default region (e.g., `eu-west-1` or `us-east-1`). Ensure this matches the `aws_region` variable in your Terraform code.

## 3. Project Initialization

Clone your repository and initialize the automation wrapper.

1. Navigate to the project directory:
   ```bash
   cd aws-lightweight-minecraft-mod-manager
   ```
2. Make the wrapper script executable:
   ```bash
   chmod +x manager.sh
   ```
3. Initialize Terraform to download the required AWS provider plugins:
   ```bash
   cd terraform
   terraform init
   cd ..
   ```

## 4. Understanding the Persistent State

This architecture is designed for $0 idle compute costs. When torn down, **all** AWS network infrastructure (VPC, Subnets, Internet Gateways, Security Groups) and compute (EC2 instance) are completely destroyed.

The only piece of infrastructure that persists between sessions is an **Amazon S3 Bucket**.

- The `manager.sh` script automatically creates this bucket named `mc-ephemeral-worlds-<YOUR_AWS_ACCOUNT_ID>`.
- Because it is created via the AWS CLI in the wrapper script (not inside `main.tf`), running `terraform destroy` will **not** delete your world saves.
- S3 storage costs roughly $0.023 per GB per month. A typical Minecraft world backup costs a few pennies per month.
