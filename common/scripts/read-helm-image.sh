#!/usr/bin/env bash
# Read image.fullRef from a Helm values file (simple YAML parse, no yq required).
set -euo pipefail

VALUES_FILE="${1:?Usage: read-helm-image.sh <values.yaml>}"

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "Values file not found: ${VALUES_FILE}" >&2
  exit 1
fi

# Match: fullRef: quay.io/org/image:tag  (under image: block)
image="$(
  awk '
    /^image:[[:space:]]*$/ { in_image=1; next }
    in_image && /^[^[:space:]]/ { in_image=0 }
    in_image && /^[[:space:]]+fullRef:[[:space:]]*/ {
      sub(/^[[:space:]]+fullRef:[[:space:]]*/, "")
      gsub(/"/, "")
      gsub(/'"'"'/, "")
      print
      exit
    }
  ' "${VALUES_FILE}"
)"

if [[ -z "${image}" ]]; then
  echo "Could not find image.fullRef in ${VALUES_FILE}" >&2
  exit 1
fi

echo "${image}"
