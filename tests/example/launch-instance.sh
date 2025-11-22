#!/bin/bash
set -e

echo "=== Launching EC2 Instance for Ansible SSM Test ==="

# Configuration - can be overridden via environment variables
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.micro}"
REGION="${REGION:-us-west-2}"
AMI_NAME="${AMI_NAME:-al2023-ami-*-arm64}"  # Amazon Linux 2023 ARM
IAM_ROLE_NAME="${IAM_ROLE_NAME:-AnsibleSSMTestRole}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-AnsibleSSMTestProfile}"
TAG_NAME="${TAG_NAME:-ansible-ssm-test}"
AWS_PROFILE="${AWS_PROFILE:-default}"  # AWS default profile 
IAM_PROFILE="${IAM_PROFILE:-$AWS_PROFILE}"  # AWS profile with IAM permissions

# Display configuration
echo "Configuration:"
echo "  Instance Type: $INSTANCE_TYPE"
echo "  Region: $REGION"
echo "  AMI Pattern: $AMI_NAME"
echo "  IAM Role: $IAM_ROLE_NAME"
echo "  Instance Profile: $INSTANCE_PROFILE_NAME"
echo "  Tag Name: $TAG_NAME"
echo "  AWS Profile: $AWS_PROFILE"
echo "  IAM Profile: $IAM_PROFILE"
echo ""

# Find the latest Amazon Linux 2023 ARM AMI
echo "Finding latest Amazon Linux 2023 ARM AMI..."
AMI_ID=$(aws ec2 describe-images \
  --region $REGION \
  --owners amazon \
  --filters \
    "Name=name,Values=$AMI_NAME" \
    "Name=architecture,Values=arm64" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
  echo "ERROR: Could not find Amazon Linux 2023 ARM AMI"
  exit 1
fi
echo "Using AMI: $AMI_ID"

# Check if IAM role exists, create if not
echo "Checking IAM role..."
if ! aws iam get-role --role-name $IAM_ROLE_NAME --profile $IAM_PROFILE &>/dev/null; then
  echo "Creating IAM role for SSM (using profile: $IAM_PROFILE)..."

  # Create trust policy
  cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

  aws iam create-role \
    --profile $IAM_PROFILE \
    --role-name $IAM_ROLE_NAME \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    --description "Role for EC2 instances to use AWS Systems Manager"

  # Attach AWS managed policy for SSM
  aws iam attach-role-policy \
    --profile $IAM_PROFILE \
    --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

  echo "IAM role created and policy attached"
  rm /tmp/trust-policy.json
else
  echo "IAM role already exists"
fi

# Check if instance profile exists, create if not
echo "Checking instance profile..."
if ! aws iam get-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME --profile $IAM_PROFILE &>/dev/null; then
  echo "Creating instance profile (using profile: $IAM_PROFILE)..."
  aws iam create-instance-profile \
    --profile $IAM_PROFILE \
    --instance-profile-name $INSTANCE_PROFILE_NAME

  aws iam add-role-to-instance-profile \
    --profile $IAM_PROFILE \
    --instance-profile-name $INSTANCE_PROFILE_NAME \
    --role-name $IAM_ROLE_NAME

  echo "Instance profile created"
  # Wait for instance profile to be ready
  sleep 10
else
  echo "Instance profile already exists"

  # Verify role is attached to instance profile
  PROFILE_ROLE=$(aws iam get-instance-profile \
    --instance-profile-name $INSTANCE_PROFILE_NAME \
    --profile $IAM_PROFILE \
    --query "InstanceProfile.Roles[0].RoleName" \
    --output text 2>/dev/null)

  if [ "$PROFILE_ROLE" = "None" ] || [ -z "$PROFILE_ROLE" ]; then
    echo "Role not attached to instance profile, attaching..."
    aws iam add-role-to-instance-profile \
      --profile $IAM_PROFILE \
      --instance-profile-name $INSTANCE_PROFILE_NAME \
      --role-name $IAM_ROLE_NAME
    echo "Role attached to instance profile"
  else
    echo "Role '$PROFILE_ROLE' is attached to instance profile"
  fi
fi

# Get default VPC and subnet
echo "Getting default VPC information..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region $REGION \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" \
  --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[0].SubnetId" \
  --output text)

echo "Using VPC: $VPC_ID"
echo "Using Subnet: $SUBNET_ID"

# Create SSM parameter for hostname configuration
echo "Creating SSM parameter for hostname configuration..."
aws ssm put-parameter \
  --name "/example/config/hostname" \
  --value "banana" \
  --type "String" \
  --description "Desired hostname for Ansible SSM test instance" \
  --overwrite \
  --region $REGION 2>&1 | grep -v "ParameterAlreadyExists" || true
echo "SSM parameter /example/config/hostname set to 'banana'"

# Create S3 bucket for SSM session data if it doesn't exist
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="ansible-ssm-${ACCOUNT_ID}-${REGION}"
echo "Checking S3 bucket for SSM session data..."
if ! aws s3 ls "s3://${BUCKET_NAME}" --region $REGION &>/dev/null; then
  echo "Creating S3 bucket: ${BUCKET_NAME}"
  aws s3 mb "s3://${BUCKET_NAME}" --region $REGION
  echo "S3 bucket created"
else
  echo "S3 bucket already exists: ${BUCKET_NAME}"
fi

# Launch the instance
echo "Launching instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region $REGION \
  --image-id $AMI_ID \
  --instance-type $INSTANCE_TYPE \
  --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
  --subnet-id $SUBNET_ID \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_NAME}]" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1" \
  --query "Instances[0].InstanceId" \
  --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "ERROR: Failed to launch instance"
  exit 1
fi

echo ""
echo "=== Instance Launched Successfully ==="
echo "Instance ID: $INSTANCE_ID"
echo "Instance Type: $INSTANCE_TYPE"
echo "Region: $REGION"
echo "Tag: Name=$TAG_NAME"
echo ""
echo "Waiting for instance to be running..."

# Wait for instance to be running
aws ec2 wait instance-running \
  --region $REGION \
  --instance-ids $INSTANCE_ID

echo "Instance is running!"
echo ""
echo "=== Next Steps ==="
echo "1. Wait 2-3 minutes for SSM agent to register"
echo "2. Check SSM status:"
echo "   aws ssm describe-instance-information --filters \"Key=tag:Name,Values=$TAG_NAME\""
echo ""
echo "3. Verify SSM parameter hostname is set to 'banana':"
echo "   aws ssm get-parameter --name \"/example/config/hostname\" --query \"Parameter.Value\" --output text"
echo ""
echo "4. Run Ansible playbook:"
echo "   ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml"
echo ""
echo "5. When done, cleanup with:"
echo "   ./cleanup.sh"
echo ""
echo "Instance ID saved to: instance-id.txt"
echo $INSTANCE_ID > instance-id.txt
