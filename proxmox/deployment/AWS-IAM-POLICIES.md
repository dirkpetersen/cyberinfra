# AWS IAM Policies for Proxmox pve1 Cluster

## Overview

This document defines IAM roles and policies required for the Proxmox cluster to access AWS services (SSM Parameter Store, S3, etc.).

---

## IAM Role: pve1-node-role

### Role Assume Policy

This allows EC2 instances (or any resource with this role) to assume this role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": [
          "ec2.amazonaws.com",
          "ssm.amazonaws.com"
        ],
        "AWS": "*"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

---

## IAM Policy: pve1-ssm-access

Allows access to AWS SSM Parameter Store for configuration management:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "arn:aws:ssm:us-west-2:ACCOUNT_ID:parameter/pve1/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:PutParameter"
      ],
      "Resource": "arn:aws:ssm:us-west-2:ACCOUNT_ID:parameter/pve1/*",
      "Condition": {
        "StringEquals": {
          "ssm:Overwrite": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "arn:aws:kms:us-west-2:ACCOUNT_ID:key/KMS_KEY_ID",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "ssm.us-west-2.amazonaws.com"
        }
      }
    }
  ]
}
```

---

## IAM Policy: pve1-s3-backup-access

Allows access to S3 bucket for backup storage:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketVersions"
      ],
      "Resource": "arn:aws:s3:::pve1-backups"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::pve1-backups/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketVersioning"
      ],
      "Resource": "arn:aws:s3:::pve1-backups"
    }
  ]
}
```

---

## IAM Policy: pve1-secrets-access

Allows access to AWS Secrets Manager for credentials:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "arn:aws:secretsmanager:us-west-2:ACCOUNT_ID:secret:pve1/*"
    }
  ]
}
```

---

## IAM Policy: pve1-ansible-access

Allows Ansible running on Proxmox to manage AWS resources:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
        "ssm:PutParameter"
      ],
      "Resource": "arn:aws:ssm:us-west-2:ACCOUNT_ID:parameter/pve1/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeImages",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeNetworkInterfaces"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-west-2"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:us-west-2:ACCOUNT_ID:log-group:/pve1/*"
    }
  ]
}
```

---

## IAM Policy: pve1-cloudwatch-monitoring

Allows publishing metrics to CloudWatch:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "cloudwatch:namespace": "pve1/cluster"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:us-west-2:ACCOUNT_ID:log-group:/pve1/*"
    }
  ]
}
```

---

## IAM Role Assembly

### Create Role in AWS

```bash
# Create the IAM role
aws iam create-role \
    --role-name pve1-node-role \
    --assume-role-policy-document file://assume-policy.json \
    --region us-west-2

# Attach policies to role
aws iam attach-role-policy \
    --role-name pve1-node-role \
    --policy-arn arn:aws:iam::ACCOUNT_ID:policy/pve1-ssm-access \
    --region us-west-2

aws iam attach-role-policy \
    --role-name pve1-node-role \
    --policy-arn arn:aws:iam::ACCOUNT_ID:policy/pve1-s3-backup-access \
    --region us-west-2

aws iam attach-role-policy \
    --role-name pve1-node-role \
    --policy-arn arn:aws:iam::ACCOUNT_ID:policy/pve1-secrets-access \
    --region us-west-2

aws iam attach-role-policy \
    --role-name pve1-node-role \
    --policy-arn arn:aws:iam::ACCOUNT_ID:policy/pve1-cloudwatch-monitoring \
    --region us-west-2

# Create instance profile
aws iam create-instance-profile \
    --instance-profile-name pve1-node-profile \
    --region us-west-2

# Add role to instance profile
aws iam add-role-to-instance-profile \
    --instance-profile-name pve1-node-profile \
    --role-name pve1-node-role \
    --region us-west-2
```

---

## On-Premises Proxmox (Non-AWS Setup)

If Proxmox nodes are on-premises and not in AWS, use explicit AWS credentials:

### Method 1: Environment Variables

```bash
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
export AWS_DEFAULT_REGION="us-west-2"
```

### Method 2: AWS Credentials File

Create `/root/.aws/credentials`:

```ini
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region = us-west-2

[pve1]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE2
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY2
region = us-west-2
```

### Method 3: AWS CLI Named Profile

```bash
# Configure named profile
aws configure --profile pve1

# Use in scripts
aws --profile pve1 ssm get-parameter --name /pve1/nodes/node1/vlan6_ip
```

---

## KMS Key Policy (For Encrypted SSM Parameters)

If using encrypted SSM parameters, the KMS key must allow access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::ACCOUNT_ID:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow pve1 role to decrypt",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::ACCOUNT_ID:role/pve1-node-role"
      },
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": [
            "ssm.us-west-2.amazonaws.com",
            "secrets-manager.us-west-2.amazonaws.com"
          ]
        }
      }
    }
  ]
}
```

---

## Verification Checklist

- [ ] IAM role created: `pve1-node-role`
- [ ] Instance profile created: `pve1-node-profile`
- [ ] All 5 policies attached to role
- [ ] KMS key policy updated (if using encrypted parameters)
- [ ] AWS credentials configured on Proxmox nodes
- [ ] `aws --profile pve1 ssm get-parameter --name /pve1/cluster/name` succeeds
- [ ] S3 bucket access verified: `aws s3 ls s3://pve1-backups/`

---

## Least Privilege Recommendation

For production, consider even more restrictive policies:

- Use separate roles per node (instead of shared role)
- Use resource tags to limit scope
- Use IP-based conditions if on stable network
- Implement session duration limits
- Enable CloudTrail for audit logging

---

## Related Documentation

- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [AWS SSM Parameter Store Security](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-security.html)
- [Secrets Manager Key Rotation](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html)

