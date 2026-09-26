#!/bin/bash
set -e

if [[ $# -lt 2 ]]; then
    echo "Usage: ./manager.sh [up|down] <curseforge_project_id>"
    echo "Example: ./manager.sh up 396246"
    exit 1
fi

ACTION=$1
PROJECT_ID=$2

# Create a unique bucket name tied to your AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="mc-ephemeral-worlds-${ACCOUNT_ID}"

if [ "$ACTION" == "up" ]; then
    # Ensure the persistent S3 bucket exists
    if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        echo "Creating S3 bucket $BUCKET_NAME for persistent world storage..."
        aws s3 mb s3://"$BUCKET_NAME"
    fi

    terraform init
    terraform apply -var="curseforge_project_id=$PROJECT_ID" -var="s3_bucket=$BUCKET_NAME" -auto-approve

elif [ "$ACTION" == "down" ]; then
    echo "Destroying infrastructure. The server will automatically backup to S3 before dying."
    terraform destroy -var="curseforge_project_id=$PROJECT_ID" -var="s3_bucket=$BUCKET_NAME" -auto-approve
fi