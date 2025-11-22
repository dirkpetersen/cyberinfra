# Environment Variables Reference

All scripts in this example support environment variable overrides for flexible configuration.

## Quick Reference

### launch-instance.sh

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTANCE_TYPE` | `t4g.micro` | EC2 instance type |
| `REGION` | `us-west-2` | AWS region |
| `AMI_NAME` | `al2023-ami-*-arm64` | AMI search pattern |
| `IAM_ROLE_NAME` | `AnsibleSSMTestRole` | IAM role for EC2 instance |
| `INSTANCE_PROFILE_NAME` | `AnsibleSSMTestProfile` | IAM instance profile |
| `TAG_NAME` | `ansible-ssm-test` | EC2 instance tag for filtering |
| `IAM_PROFILE` | `iam-dirk` | AWS CLI profile for IAM operations |

### cleanup.sh

| Variable | Default | Description |
|----------|---------|-------------|
| `REGION` | `us-west-2` | AWS region (must match launch) |
| `TAG_NAME` | `ansible-ssm-test` | Instance tag (must match launch) |
| `IAM_PROFILE` | `iam-dirk` | AWS CLI profile for IAM operations |

## Usage Examples

### Basic Override

```bash
# Change instance type
INSTANCE_TYPE=t4g.small ./launch-instance.sh

# Use different region
REGION=us-east-1 ./launch-instance.sh

# Use your own IAM profile
IAM_PROFILE=my-admin ./launch-instance.sh
```

### Multiple Overrides

```bash
# Launch in different region with larger instance
REGION=us-east-1 \
INSTANCE_TYPE=t4g.medium \
TAG_NAME=my-test \
./launch-instance.sh
```

### Cleanup with Matching Values

**Important**: Cleanup must use the same `REGION` and `TAG_NAME` as launch:

```bash
# Match the launch configuration
REGION=us-east-1 \
TAG_NAME=my-test \
./cleanup.sh
```

## Common Scenarios

### Testing in Multiple Regions

```bash
# Launch in us-west-2 (default)
./launch-instance.sh

# Launch in us-east-1
REGION=us-east-1 TAG_NAME=test-east ./launch-instance.sh

# Launch in eu-west-1
REGION=eu-west-1 TAG_NAME=test-eu ./launch-instance.sh

# Cleanup all
./cleanup.sh
REGION=us-east-1 TAG_NAME=test-east ./cleanup.sh
REGION=eu-west-1 TAG_NAME=test-eu ./cleanup.sh
```

### Using Different Instance Types

```bash
# Free tier ARM (default)
./launch-instance.sh

# Larger ARM instance
INSTANCE_TYPE=t4g.small TAG_NAME=test-small ./launch-instance.sh

# x86_64 instance (requires different AMI)
INSTANCE_TYPE=t3.micro \
AMI_NAME="al2023-ami-*-x86_64" \
TAG_NAME=test-x86 \
./launch-instance.sh
```

### Different IAM Profile

```bash
# If your IAM profile is named differently
IAM_PROFILE=admin-profile ./launch-instance.sh

# Cleanup with same profile
IAM_PROFILE=admin-profile ./cleanup.sh
```

## Environment Variable Precedence

1. **Command line**: `REGION=us-east-1 ./launch-instance.sh`
2. **Exported shell variable**: `export REGION=us-east-1; ./launch-instance.sh`
3. **Script default**: Falls back to hardcoded default if not set

## Tips

### Set Once for Multiple Commands

```bash
# Export variables for the session
export REGION=us-east-1
export TAG_NAME=my-test
export INSTANCE_TYPE=t4g.small

# All commands will use these values
./launch-instance.sh
# ... wait for instance ...
ansible-playbook -i inventory.aws_ec2.yml change-hostname.yml
./cleanup.sh
```

### Create a Configuration File

```bash
# Create config.env
cat > config.env <<EOF
REGION=us-east-1
INSTANCE_TYPE=t4g.small
TAG_NAME=my-test
IAM_PROFILE=my-admin
EOF

# Source and use
source config.env
./launch-instance.sh
```

### Verify Configuration

Both scripts display their configuration at startup:

```bash
$ ./launch-instance.sh
=== Launching EC2 Instance for Ansible SSM Test ===
Configuration:
  Instance Type: t4g.micro
  Region: us-west-2
  AMI Pattern: al2023-ami-*-arm64
  IAM Role: AnsibleSSMTestRole
  Instance Profile: AnsibleSSMTestProfile
  Tag Name: ansible-ssm-test
  IAM Profile: iam-dirk
...
```

This allows you to verify settings before resources are created.
