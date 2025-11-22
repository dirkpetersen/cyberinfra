# Troubleshooting Guide

## Common Issues and Solutions

### SSM Agent Not Registering

**Symptom**: After launching instance, `aws ssm describe-instance-information` returns empty list after 3+ minutes.

**Check**:
```bash
# Check if instance is running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ansible-ssm-test" \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name,IamInstanceProfile.Arn]" \
  --output table

# Check console logs for errors
aws ec2 get-console-output --instance-id i-XXXXX --latest
```

**Common Causes**:

#### 1. IAM Instance Profile Missing Role

**Error in console logs**:
```
SSM Agent unable to acquire credentials: no valid credentials could be retrieved for ec2 identity
```

**Solution**: The instance profile exists but has no role attached. This happens if the instance profile was created in a previous run but the role was removed.

The `launch-instance.sh` script now automatically detects and fixes this issue (version 2.0+). For older versions or manual fix:

```bash
# Check if role is attached
aws iam get-instance-profile \
  --instance-profile-name AnsibleSSMTestProfile \
  --profile iam-dirk \
  --query "InstanceProfile.Roles[0].RoleName"

# If output is "None" or empty, attach the role
aws iam add-role-to-instance-profile \
  --instance-profile-name AnsibleSSMTestProfile \
  --role-name AnsibleSSMTestRole \
  --profile iam-dirk

# Restart instance to pick up credentials
aws ec2 stop-instances --instance-ids i-XXXXX
aws ec2 wait instance-stopped --instance-ids i-XXXXX
aws ec2 start-instances --instance-ids i-XXXXX
aws ec2 wait instance-running --instance-ids i-XXXXX

# Wait 60 seconds for SSM agent to register
sleep 60
aws ssm describe-instance-information \
  --filters "Key=tag:Name,Values=ansible-ssm-test"
```

#### 2. Security Group Blocking Outbound HTTPS

SSM agent needs to connect to AWS endpoints on port 443.

**Check**:
```bash
aws ec2 describe-instances \
  --instance-ids i-XXXXX \
  --query "Reservations[0].Instances[0].SecurityGroups[*].[GroupId,GroupName]"
```

**Solution**: Ensure security group allows outbound HTTPS (port 443).

#### 3. IAM Policy Missing

**Check**:
```bash
aws iam list-attached-role-policies \
  --role-name AnsibleSSMTestRole \
  --profile iam-dirk
```

**Expected output**:
```
AmazonSSMManagedInstanceCore
```

**Solution**: If missing, attach the policy:
```bash
aws iam attach-role-policy \
  --role-name AnsibleSSMTestRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --profile iam-dirk
```

### Ansible Connection Fails

**Symptom**: `ansible-playbook` fails with "failed to find the executable specified /usr/local/bin/session-manager-plugin"

**Solution**: Install Session Manager plugin:
```bash
./install-session-manager-plugin.sh
```

**Symptom**: `ansible-playbook` fails with "No hosts matched"

**Debug**:
```bash
# Check dynamic inventory
ansible-inventory -i inventory.aws_ec2.yml --list

# Verify instance has correct tag
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ansible-ssm-test" \
  --query "Reservations[*].Instances[*].InstanceId"
```

**Solution**: Ensure instance has tag `Name=ansible-ssm-test` and is in `running` state.

**Symptom**: `ansible-playbook` fails with "Invalid bucket name" or "expected string or bytes-like object, got 'NoneType'"

**Cause**: S3 bucket for SSM session data not configured properly.

**Solution**: The `launch-instance.sh` script automatically creates the bucket. If running manually:
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 mb s3://ansible-ssm-${ACCOUNT_ID}-us-west-2 --region us-west-2
```

Then ensure `inventory.aws_ec2.yml` has the bucket name in the compose section.

### Instance Profile vs IAM Role Confusion

**Important**: Understanding the relationship:

- **IAM Role**: Defines permissions (what the instance can do)
- **Instance Profile**: Container that passes the role to EC2
- **Relationship**: Instance Profile → contains → IAM Role

The instance needs BOTH:
1. IAM Role with `AmazonSSMManagedInstanceCore` policy
2. Instance Profile with the role attached
3. Instance Profile attached to the EC2 instance

**Verify all three**:
```bash
# 1. Check role exists and has policy
aws iam get-role --role-name AnsibleSSMTestRole --profile iam-dirk
aws iam list-attached-role-policies --role-name AnsibleSSMTestRole --profile iam-dirk

# 2. Check instance profile has role
aws iam get-instance-profile \
  --instance-profile-name AnsibleSSMTestProfile \
  --profile iam-dirk \
  --query "InstanceProfile.Roles[0].RoleName"

# 3. Check EC2 instance has instance profile
aws ec2 describe-instances \
  --instance-ids i-XXXXX \
  --query "Reservations[0].Instances[0].IamInstanceProfile.Arn"
```

### Environment Variable Issues

**Symptom**: Script uses wrong region/tag/profile

**Debug**: Scripts display configuration at startup. Check the output:
```bash
./launch-instance.sh
# Should show:
# Configuration:
#   Instance Type: t4g.micro
#   Region: us-west-2
#   ...
```

**Solution**: Export variables or pass inline:
```bash
# Inline (preferred for one-time use)
REGION=us-east-1 TAG_NAME=my-test ./launch-instance.sh

# Exported (for multiple commands)
export REGION=us-east-1
export TAG_NAME=my-test
./launch-instance.sh
./cleanup.sh
```

### Permissions Issues

**Symptom**: `AccessDeniedException` or `UnauthorizedException`

**For IAM operations** (role/instance profile creation):
```bash
# Test IAM profile access
aws sts get-caller-identity --profile iam-dirk
```

**For EC2/SSM/S3 operations**:
```bash
# Test default profile access
aws sts get-caller-identity
```

**Solution**: See README.md "Required IAM Permissions" section for complete policy JSON.

### Multiple Instances with Same Tag

**Symptom**: Ansible targets wrong instance or multiple instances

**Debug**:
```bash
ansible-inventory -i inventory.aws_ec2.yml --list | jq '.all.hosts'
```

**Solution**: Use unique tag names:
```bash
TAG_NAME=test-$(date +%s) ./launch-instance.sh
```

Or cleanup old instances:
```bash
./cleanup.sh
```

## Getting Help

### Enable Verbose Output

**Ansible**:
```bash
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml -vvv
```

**AWS CLI**:
```bash
aws ssm describe-instance-information --debug
```

### Check Instance Console Output

```bash
aws ec2 get-console-output --instance-id i-XXXXX --latest --output text
```

Look for SSM agent errors near the end.

### Interactive SSM Session

Test SSM connectivity directly:
```bash
aws ssm start-session --target i-XXXXX
```

If this works but Ansible fails, the issue is with Ansible/Python configuration, not SSM.

### Verify All Components

Run this comprehensive check:
```bash
echo "=== EC2 Instance ==="
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ansible-ssm-test" \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name,IamInstanceProfile.Arn]" \
  --output table

echo -e "\n=== SSM Registration ==="
aws ssm describe-instance-information \
  --filters "Key=tag:Name,Values=ansible-ssm-test" \
  --query "InstanceInformationList[*].[InstanceId,PingStatus]" \
  --output table

echo -e "\n=== IAM Role Policy ==="
aws iam list-attached-role-policies \
  --role-name AnsibleSSMTestRole \
  --profile iam-dirk \
  --output table

echo -e "\n=== Instance Profile Role ==="
aws iam get-instance-profile \
  --instance-profile-name AnsibleSSMTestProfile \
  --profile iam-dirk \
  --query "InstanceProfile.Roles[0].RoleName" \
  --output text

echo -e "\n=== S3 Bucket ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 ls s3://ansible-ssm-${ACCOUNT_ID}-us-west-2/ 2>&1 | head -1

echo -e "\n=== Session Manager Plugin ==="
session-manager-plugin --version

echo -e "\n=== Ansible Inventory ==="
ansible-inventory -i inventory.aws_ec2.yml --list | jq '.all.hosts'
```

Save as `verify.sh` for easy diagnostics.
