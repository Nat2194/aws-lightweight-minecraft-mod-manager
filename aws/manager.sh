#!/bin/bash
set -e

if [[ $# -lt 2 ]]; then
    echo "Usage: ./manager.sh [up|down] <curseforge_project_id> [--skip-bucket]"
    echo "Example: ./manager.sh up 1108726"
    exit 1
fi

ACTION=$1
PROJECT_ID=$2
FLAG=$3

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    echo "Loading AWS credentials from .env..."
    set -o allexport
    source .env
    set +o allexport
fi

# Verify AWS credentials are set
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Error: AWS credentials not found. Please set them in a .env file or run 'aws configure'."
    exit 1
fi

# Create a unique bucket name tied to your AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="mc-ephemeral-worlds-${ACCOUNT_ID}"

if [ "$ACTION" == "up" ]; then
    # Check if the bucket exists
    if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        if [ "$FLAG" == "--skip-bucket" ]; then
            echo "Skipping S3 bucket creation as requested via flag."
        else
            echo "S3 bucket '$BUCKET_NAME' does not exist."
            read -p "Do you want to create it now for world backups? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Creating S3 bucket $BUCKET_NAME..."
                aws s3 mb s3://"$BUCKET_NAME"
            else
                echo "Warning: Running without an S3 bucket. World saves and configs will NOT be backed up upon shutdown!"
            fi
        fi
    fi

    cd terraform
    terraform init
    terraform apply -var="curseforge_project_id=$PROJECT_ID" -var="s3_bucket=$BUCKET_NAME" -auto-approve
    cd ..

elif [ "$ACTION" == "down" ]; then
    echo "Destroying infrastructure. The server will attempt to backup to S3 before dying."
    cd terraform
    terraform destroy -var="curseforge_project_id=$PROJECT_ID" -var="s3_bucket=$BUCKET_NAME" -auto-approve
    cd ..
fi