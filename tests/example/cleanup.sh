#!/bin/bash
set -e

echo "=== Cleaning Up EC2 Instance ==="

# Configuration - can be overridden via environment variables
REGION="${REGION:-us-west-2}"
TAG_NAME="${TAG_NAME:-ansible-ssm-test}"
AWS_PROFILE="${AWS_PROFILE:-default}"  # AWS default profile
IAM_PROFILE="${IAM_PROFILE:-$AWS_PROFILE}"  # AWS profile with IAM permissions

echo "Configuration:"
echo "  Region: $REGION"
echo "  Tag Name: $TAG_NAME"
echo "  AWS Profile: $AWS_PROFILE"
echo "  IAM Profile: $IAM_PROFILE"
echo ""

# Check if instance-id.txt exists
if [ -f "instance-id.txt" ]; then
  INSTANCE_ID=$(cat instance-id.txt)
  echo "Found instance ID from file: $INSTANCE_ID"
else
  # Try to find instance by tag
  echo "Looking up instance by tag..."
  INSTANCE_ID=$(aws ec2 describe-instances \
    --region $REGION \
    --filters \
      "Name=tag:Name,Values=$TAG_NAME" \
      "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

  if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    echo "No instance found with tag Name=$TAG_NAME"
    echo "Nothing to clean up."
    exit 0
  fi
fi

# Terminate the instance
echo "Terminating instance: $INSTANCE_ID"
aws ec2 terminate-instances \
  --region $REGION \
  --instance-ids $INSTANCE_ID \
  --output text

echo "Instance termination initiated"
echo ""
echo "Waiting for instance to terminate..."
aws ec2 wait instance-terminated \
  --region $REGION \
  --instance-ids $INSTANCE_ID

echo "Instance terminated successfully"

# Clean up SSM parameter
echo ""
echo "Deleting SSM parameter..."
if aws ssm delete-parameter --name "/example/config/hostname" --region $REGION 2>&1 | grep -q "ParameterNotFound"; then
  echo "SSM parameter /example/config/hostname not found (already deleted)"
else
  echo "SSM parameter /example/config/hostname deleted"
fi

# Clean up local files
if [ -f "instance-id.txt" ]; then
  rm instance-id.txt
  echo "Removed instance-id.txt"
fi

echo ""
echo "=== Cleanup Complete ==="
echo ""
echo "Note: IAM role and instance profile were NOT deleted."
echo "They can be reused for future tests."
echo ""
echo "To manually delete them (requires IAM permissions via profile $IAM_PROFILE):"
echo "  aws iam remove-role-from-instance-profile --profile $IAM_PROFILE --instance-profile-name AnsibleSSMTestProfile --role-name AnsibleSSMTestRole"
echo "  aws iam delete-instance-profile --profile $IAM_PROFILE --instance-profile-name AnsibleSSMTestProfile"
echo "  aws iam detach-role-policy --profile $IAM_PROFILE --role-name AnsibleSSMTestRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
echo "  aws iam delete-role --profile $IAM_PROFILE --role-name AnsibleSSMTestRole"
