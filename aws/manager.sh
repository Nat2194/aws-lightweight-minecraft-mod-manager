#!/bin/bash

# 1. Setup automatic logging to both console and file
LOG_FILE="last_run.log"
exec > >(tee "$LOG_FILE") 2>&1

echo "[INFO] Starting Minecraft Ephemeral Server Manager..."

# Function to pause before exiting so the window doesn't instantly close
pause_and_exit() {
    echo ""
    read -n 1 -s -r -p "Press any key to exit..."
    echo ""
    exit $1
}

if [[ $# -lt 2 ]]; then
    echo "[ERROR] Missing arguments."
    echo "Usage: ./manager.sh [up|down] <curseforge_project_id> [--skip-bucket]"
    pause_and_exit 1
fi

ACTION=$1
PROJECT_ID=$2
FLAG=$3

if ! command -v aws &> /dev/null || ! command -v terraform &> /dev/null; then
    echo "[ERROR] AWS CLI or Terraform is missing from your system."
    pause_and_exit 1
fi

if [ -f .env ]; then
    echo "[INFO] Loading AWS credentials from .env..."
    sed -i -e 's/\r$//' .env 2>/dev/null || true
    set -o allexport
    source .env
    set +o allexport
fi

echo "[INFO] Authenticating with AWS..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>&1)
if [[ $? -ne 0 ]]; then
    echo "[ERROR] AWS Authentication failed. Check your .env file."
    echo "$ACCOUNT_ID"
    pause_and_exit 1
fi
echo "[SUCCESS] Authenticated successfully (Account ID: $ACCOUNT_ID)."

BUCKET_NAME="mc-ephemeral-worlds-${ACCOUNT_ID}"
export TF_VAR_s3_enabled="true"

if [ "$ACTION" == "up" ]; then
    echo "[INFO] Checking S3 bucket status..."
    if ! aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        if [ "$FLAG" == "--skip-bucket" ]; then
            echo "[INFO] Skipping S3 bucket creation (--skip-bucket)."
            export TF_VAR_s3_enabled="false"
        else
            echo "[WARN] S3 bucket '$BUCKET_NAME' does not exist."
            read -p "Do you want to create it now for world backups? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                aws s3 mb s3://"$BUCKET_NAME"
                echo "[SUCCESS] Bucket created."
            else
                export TF_VAR_s3_enabled="false"
                echo "[WARN] Running without an S3 bucket. World saves and configs will NOT be backed up!"
            fi
        fi
    fi

    cd terraform || pause_and_exit 1
    echo "[INFO] Initializing Terraform..."
    terraform init -upgrade > /dev/null

    echo "======================================================"
    echo "             AWS CHANGES TO BE APPLIED                "
    echo "======================================================"
    terraform plan -var="curseforge_project_id=$PROJECT_ID" -var="s3_bucket=$BUCKET_NAME" -out=tfplan
    echo "======================================================"
    
    read -p "Do you want to proceed and create these AWS resources? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "[INFO] Provisioning AWS Infrastructure..."
        terraform apply tfplan
        echo "[SUCCESS] Deployment finished! Check Discord or wait 5 minutes to connect."
    else
        echo "[INFO] Deployment cancelled."
        pause_and_exit 0
    fi
    cd ..

elif [ "$ACTION" == "down" ]; then
    cd terraform || pause_and_exit 1
    echo "======================================================"
    echo "            AWS RESOURCES TO BE DESTROYED             "
    echo "======================================================"
    terraform plan -destroy -var="curseforge_project_id=$PROJECT_ID" -var="s3_bucket=$BUCKET_NAME"
    echo "======================================================"
    
    read -p "Do you want to proceed with destroying the server? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "[INFO] Initiating infrastructure teardown..."
        terraform destroy -var="curseforge_project_id=$PROJECT_ID" -var="s3_bucket=$BUCKET_NAME" -auto-approve
        echo "[SUCCESS] Infrastructure destroyed. Billing stopped."
    else
        echo "[INFO] Teardown cancelled."
        pause_and_exit 0
    fi
    cd ..
else
    echo "[ERROR] Invalid action. Use 'up' or 'down'."
    pause_and_exit 1
fi

pause_and_exit 0