#!/usr/bin/env bash
# Build the host image into a real AMI and register it in your AWS account,
# via bootc-image-builder's all-in-one AWS upload path (--aws-ami-name/
# --aws-bucket/--aws-region must all be given together, or it just exports
# a local disk.raw instead of uploading). No local QEMU/KVM boot needed —
# assembling the disk image doesn't require hardware virtualization.
#
# Credential/invocation pattern lifted from the proven
# ~/bootc-demos/demos/05-create-ami-deploy-ec2/run.sh on the build VM (same
# AWS account) rather than reinvented — notably: the build VM has no
# ~/.aws, it authenticates via the EC2 instance role over IMDS instead, which
# requires --network host on the builder container so it can reach the
# 169.254.169.254 metadata endpoint.
#
# Prerequisites (one-time, per AWS account):
#   - An S3 bucket for the upload (defaults to the one already used by
#     bootc-demos: rhkp-bootc-demo-staging)
#   - The `vmimport` IAM service role AWS requires for image import
#
# Run on the AWS build VM — no Podman Desktop, no GUI, plain CLI throughout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTC_VM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PODMAN="${PODMAN:-podman}"
HOST_IMAGE="${HOST_IMAGE:-quay.io/rhkp/openrmf-office-bootc-host:latest}"
AWS_AMI_NAME="${AWS_AMI_NAME:-rhkp-openrmf-office-bootc-host}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ARCH="${AWS_ARCH:-amd64}"
# fedora-bootc (unlike centos-bootc/rhel-bootc) has no default root
# filesystem type registered — bib fails with "missing required info:
# DefaultRootFs" / "no default root filesystem type specified" without this.
ROOTFS="${ROOTFS:-xfs}"
# Reuses the bucket already provisioned/working for bootc-demos in this account.
S3_BUCKET="${S3_BUCKET:-rhkp-bootc-demo-staging}"

# bib no longer pulls images itself — it needs HOST_IMAGE already present in
# root's podman storage (which is a separate auth/storage namespace from the
# invoking user's rootless podman). Pull explicitly rather than relying on
# --pull=newer (that only refreshes the bootc-image-builder tool image itself).
echo "Pulling ${HOST_IMAGE} into root's podman storage..."
sudo "${PODMAN}" pull "${HOST_IMAGE}"

# Logically bound images (Quadlet units under containers/*.container) must
# ALREADY be present in the invoking host's default container store before
# `bootc install` runs — bootc copies them in from there at install time, it
# does not fetch them itself (confirmed by a real failure: "resolving bound
# image ...: does not resolve to an image ID", from bib's install step
# running with --skip-fetch-check). Pull every bound image's Image= value
# too, not just HOST_IMAGE.
for unit in "${BOOTC_VM_DIR}"/containers/*.container; do
  bound_image="$(sed -n 's/^Image=//p' "${unit}")"
  echo "Pulling bound image ${bound_image} (from $(basename "${unit}"))..."
  sudo "${PODMAN}" pull "${bound_image}"
done

cred=()
if [ -d "$HOME/.aws" ]; then
  cred+=(-v "$HOME/.aws:/root/.aws:ro" --env "AWS_PROFILE=${AWS_PROFILE:-default}")
  echo "Using AWS credentials from ~/.aws"
else
  cred+=(--network host --env "AWS_REGION=${AWS_REGION}")
  echo "No ~/.aws — using the EC2 instance role via IMDS (host network for the builder)"
fi
tty=(); [ -t 0 ] && tty=(-it)

# The container-storage mount is required unconditionally, even when
# HOST_IMAGE is a registry reference rather than a local/localhost: image —
# confirmed by a real build failure without it ("could not access container
# storage, did you forget -v .../containers/storage:...").

echo "Building AMI '${AWS_AMI_NAME}' from ${HOST_IMAGE} in ${AWS_REGION}, staged via s3://${S3_BUCKET}..."
echo "This uploads a disk to S3 and registers an AMI — billable."
sudo "${PODMAN}" run --rm "${tty[@]}" \
  --privileged --pull=newer \
  --security-opt label=type:unconfined_t \
  -v "${BOOTC_VM_DIR}/config.toml:/config.toml:ro" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "${cred[@]}" \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type ami \
  --target-arch "${AWS_ARCH}" \
  --rootfs "${ROOTFS}" \
  --config /config.toml \
  --aws-ami-name "${AWS_AMI_NAME}" \
  --aws-bucket "${S3_BUCKET}" \
  --aws-region "${AWS_REGION}" \
  "${HOST_IMAGE}"

echo "Done. Find the new AMI ID via:"
echo "  aws ec2 describe-images --owners self --filters Name=name,Values=${AWS_AMI_NAME} --region ${AWS_REGION} --query 'Images[0].ImageId' --output text"
