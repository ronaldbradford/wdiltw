#!/usr/bin/env bash
set -euo pipefail

# RDS Proxy Setup
# Based on https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/rds-proxy.html
# Command Syntax: https://docs.aws.amazon.com/cli/latest/reference/rds/
# 1. Network pre-requistes
# 2. Secrets Manager setup (use existing)
# 3. IAM Policies
# 4. Proxy Role (KMS access to Secrets)
# 5. Proxy Setup

# Fixed Variable Declarations
AWS_ROLE="RDSAdministrator"
PRODUCT="rds"
ENV="demo"
SYSTEM="snow"
LOCALE="ric"  # us-east-1 Richmond IATA

CLUSTER_ID=${ENV}-${SYSTEM}-${LOCALE}
INSTANCE_ID=${CLUSTER_ID}-0
PROXY_ID=${CLUSTER_ID}-proxy-0
MASTER_USER="${PRODUCT}-${SYSTEM}/master"
WRITER_USER="${PRODUCT}-${SYSTEM}/${SYSTEM}_rw"
READER_USER="${PRODUCT}-${SYSTEM}/${SYSTEM}_ro"
KMS_ALIAS="${ENV}-${SYSTEM}-kms"
ROLE_NAME="${ENV}-${SYSTEM}-proxy-role"

# Dynamic Variable Declarations
VPC_ID=$(aws rds describe-db-instances --db-instance-id ${INSTANCE_ID} --query '*[].[DBSubnetGroup]|[0]|[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=${VPC_ID} --query '*[].[SubnetId]' --output text)
VPC_SGS=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${CLUSTER_ID}-sg" | jq -r .SecurityGroups[].GroupId)
echo "${VPC_ID},${SUBNETS},${VPC_SGS}"

WRITER_ARN=$(aws secretsmanager get-secret-value --secret-id  ${WRITER_USER} | jq -r '.ARN')
READER_ARN=$(aws secretsmanager get-secret-value --secret-id  ${READER_USER} | jq -r '.ARN')
KMS_ARN=$(aws kms describe-key --key-id alias/${KMS_ALIAS} | jq -r .KeyMetadata.Arn)
echo "${WRITER_ARN},${READER_ARN},${KMS_ARN}"

#ACCOUNT_ID=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .accountId)
ACCOUNT_ID=$(cut -d: -f5 <<< ${ADMIN_ARN})
REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
echo '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": "secretsmanager:GetSecretValue",
            "Resource": [ "'${WRITER_ARN}'", "'${READER_ARN}'" ]
        },
        {
            "Sid": "VisualEditor1",
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "'${KMS_ARN}'",
            "Condition": {
                "StringEquals": {
                    "kms:ViaService": "secretsmanager.['${REGION}'.amazonaws.com"
                }
            }
        }
    ]
}' > ${ROLE_NAME}.json

# PROXY_AUTH_JSON='[ { "Description": "DB Writer", "UserName": "'${SYSTEM}-rw'", "AuthScheme": "SECRETS","SecretArn":"'${WRITER_ARN}'", "IAMAuth": "DISABLED" }, { "Description": "DB Reader", "UserName": "'${SYSTEM}_ro'", "AuthScheme": "SECRETS","SecretArn":"'${READER_ARN}'", "IAMAuth": "DISABLED" } ]'
#An error occurred (InvalidParameterValue) when calling the CreateDBProxy operation: Username must not be provided in UserAuthConfig
PROXY_AUTH_JSON='[ { "Description": "DB Writer", "AuthScheme": "SECRETS","SecretArn":"'${WRITER_ARN}'", "IAMAuth": "DISABLED" }, { "Description": "DB Reader", "AuthScheme": "SECRETS","SecretArn":"'${READER_ARN}'", "IAMAuth": "DISABLED" } ]'
 
### ---- Real Work
jq . <<< ${PROXY_AUTH_JSON}
OUTPUT=$(aws iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["rds.amazonaws.com"]},"Action":"sts:AssumeRole"}]}')
echo $?
jq . <<< ${OUTPUT}
 
ROLE_ARN=$(aws iam get-role --role-name ${ROLE_NAME} --query '*[].Arn' --output text)
echo "${ROLE_ARN}"
jq . ${ROLE_NAME}.json
OUTPUT=$(aws iam put-role-policy --role-name ${ROLE_NAME}   --policy-name ${ENV}-${SYSTEM}-secret-reader-policy --policy-document file://${ROLE_NAME}.json)
echo $?
jq . <<< ${OUTPUT}
  
echo '{
  "Id":"'${ENV}'-'${SYSTEM}'-kms-policy",
  "Version":"2012-10-17",
  "Statement":
    [
      {
        "Sid":"Enable IAM User Permissions",
        "Effect":"Allow",
        "Principal":{"AWS":"arn:aws:iam::'${ACCOUNT_ID}':root"},
        "Action":"kms:*",
        "Resource":"*"
      },
      {
        "Sid":"Allow access for Key Administrators",
        "Effect":"Allow",
        "Principal":
          {
            "AWS":
              ["arn:aws:iam::'${ACCOUNT_ID}':role/'${AWS_ROLE}'"]
          },
        "Action":
          [
            "kms:Create*",
            "kms:Describe*",
            "kms:Enable*",
            "kms:List*",
            "kms:Put*",
            "kms:Update*",
            "kms:Revoke*",
            "kms:Disable*",
            "kms:Get*",
            "kms:Delete*",
            "kms:TagResource",
            "kms:UntagResource",
            "kms:ScheduleKeyDeletion",
            "kms:CancelKeyDeletion"
          ],
        "Resource":"*"
      },
      {
        "Sid":"Allow use of the key",
        "Effect":"Allow",
        "Principal":{"AWS":"'${ROLE_ARN}'"},
        "Action":["kms:Decrypt","kms:DescribeKey"],
        "Resource":"*"
      }
    ]
}' > ${ROLE_NAME}.policy.json
jq . ${ROLE_NAME}.policy.json

OUTPUT=$(aws kms create-key --description "${ENV}-${SYSTEM}-proxy-key" --policy file://${ROLE_NAME}.policy.json)
echo $?
jq . <<< ${OUTPUT}
 
OUTPUT=$(aws rds create-db-proxy \
    --db-proxy-name ${PROXY_ID} \
    --engine-family MYSQL \
    --auth "${PROXY_AUTH_JSON}" \
    --role-arn ${ROLE_ARN} \
    --vpc-subnet-ids ${SUBNETS} \
    --vpc-security-group-ids ${VPC_SGS} \
    --require-tls \
    --idle-client-timeout 60 \
    --tags Key=JIRA,Value=XXX-9999 \
    --debug-logging)
echo $?
jq . <<< ${OUTPUT}

while [ "${STATUS}" != "available" ] ; do
  date
  OUTPUT=$(aws rds describe-db-proxies --query '*[*].{DBProxyName:DBProxyName,Endpoint:Endpoint,Status:Status}')
  STATUS=$(jq -r '.[] | .[].Status' <<< ${OUTPUT})
  echo "${OUTPUT}"
  sleep 15
done

OUTPUT=$(aws rds register-db-proxy-targets --db-proxy-name ${CLUSTER_ID}-proxy-0  --db-cluster-identifiers ${CLUSTER_ID})
echo $?
jq . <<< ${OUTPUT}
 
 
# Check created resources
aws rds describe-db-proxies --db-proxy-name ${PROXY_ID}
aws rds describe-db-proxy-target-groups --db-proxy-name ${PROXY_ID}
aws rds describe-db-proxy-targets --db-proxy-name ${PROXY_ID}
 
# Remove created resources 
aws rds delete-db-proxy --db-proxy-name ${PROXY_ID}
