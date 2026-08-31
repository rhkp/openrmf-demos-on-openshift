#!/usr/bin/env bash
# Launch a real EC2 instance (the "VM") from the AMI build-ami.sh already
# registered — AWS's own Nitro hypervisor does the actual booting, so
# nothing here needs nested virtualization or nested KVM.
#
# Reuses the subnet + base security group already provisioned/working for
# bootc-demos in this account (checked directly: sg-01391483230b306d7 only
# opens inbound 22) rather than guessing at new ones. A second, dedicated
# security group is created here for port 8080 (noVNC) so the shared one
# isn't modified — additive, not touching what other things may depend on.
#
# No EC2 key pair required: config.toml already baked an SSH key into the
# image (see bootc-vm/README.md — base image has no cloud-init, so EC2
# key-pair injection wouldn't work anyway), matching demo 05's approach.
set -euo pipefail

AWS_AMI_NAME="${AWS_AMI_NAME:-rhkp-openrmf-office-bootc-host}"
AWS_REGION="${AWS_REGION:-us-east-1}"
# gpu_lidar needs a real GPU (software rendering silently produces no scan
# data — see README.md), and 4 robots' worth of Nav2+SLAM need real
# headroom beyond bootc-demos' generic t3.small default.
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.2xlarge}"
EC2_SUBNET_ID="${EC2_SUBNET_ID:-subnet-61a9f82c}"
BASE_SECURITY_GROUP="${BASE_SECURITY_GROUP:-sg-01391483230b306d7}"
NOVNC_SG_NAME="${NOVNC_SG_NAME:-rhkp-rmf-office-bootc-novnc}"
KEY_NAME="${KEY_NAME:-}"

_aws() { aws --region "${AWS_REGION}" "$@"; }

AMI_ID="$(_aws ec2 describe-images --owners self \
  --filters "Name=name,Values=${AWS_AMI_NAME}" --query 'Images[0].ImageId' --output text)"
if [[ "${AMI_ID}" == "None" || -z "${AMI_ID}" ]]; then
  echo "No AMI found named '${AWS_AMI_NAME}' in ${AWS_REGION} — run build-ami.sh first." >&2
  exit 1
fi
echo "Using AMI ${AMI_ID}"

VPC_ID="$(_aws ec2 describe-subnets --subnet-ids "${EC2_SUBNET_ID}" --query 'Subnets[0].VpcId' --output text)"

NOVNC_SG_ID="$(_aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${NOVNC_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [[ -z "${NOVNC_SG_ID}" || "${NOVNC_SG_ID}" == "None" ]]; then
  echo "Creating dedicated security group ${NOVNC_SG_NAME} (opens 8080 for noVNC)..."
  NOVNC_SG_ID="$(_aws ec2 create-security-group \
    --group-name "${NOVNC_SG_NAME}" \
    --description "OpenRMF office demo bootc VM - noVNC web viewer" \
    --vpc-id "${VPC_ID}" --query 'GroupId' --output text)"
  _aws ec2 authorize-security-group-ingress --group-id "${NOVNC_SG_ID}" \
    --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null
fi
echo "Using security groups ${BASE_SECURITY_GROUP} (SSH, shared) + ${NOVNC_SG_ID} (noVNC, dedicated)"

extra=()
[ -n "${KEY_NAME}" ] && extra+=(--key-name "${KEY_NAME}")

INSTANCE_ID="$(_aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --subnet-id "${EC2_SUBNET_ID}" \
  --security-group-ids "${BASE_SECURITY_GROUP}" "${NOVNC_SG_ID}" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=rhkp-rmf-office-bootc-vm}]' \
  "${extra[@]}" \
  --query 'Instances[0].InstanceId' --output text)"

echo "Launched ${INSTANCE_ID}, waiting for it to reach 'running'..."
_aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

PUBLIC_IP="$(_aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

echo "Instance running: ${INSTANCE_ID} at ${PUBLIC_IP}"
echo "  SSH:   ssh -i <your key> admin@${PUBLIC_IP}   (user/key baked via config.toml)"
echo "  Demo:  https://${PUBLIC_IP}:8080/vnc.html  (self-signed cert - browser will warn, click through)"
