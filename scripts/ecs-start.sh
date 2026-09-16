#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ecs-common.sh"

usage() {
  echo "Usage: $0 <profile> [--allow-concurrent]" >&2
  echo "Profiles: $(profile_names)" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

profile="$1"
shift
allow_concurrent=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-concurrent) allow_concurrent=true ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

configure_profile "${profile}"
require_aws_identity
show_base_context
show_profile_context

active_others=""
for other_profile in $(profile_names); do
  if [[ "${other_profile}" == "${profile}" ]]; then
    continue
  fi

  other_service="$(profile_service_name "${other_profile}")"
  if service_is_active "${other_service}"; then
    active_others="${active_others} ${other_profile}"
  fi
done

if [[ -n "${active_others}" && "${allow_concurrent}" != "true" ]]; then
  echo "Refusing to start while another profile is active:${active_others}" >&2
  echo "Stop it first, or pass --allow-concurrent and accept the additional GPU cost." >&2
  exit 1
fi

echo "Setting ECS service desired count to 1..."
aws ecs update-service \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service "${ECS_SERVICE_NAME}" \
  --desired-count 1 \
  --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount}' \
  --output table

echo
echo "The capacity provider will ensure ${ASG_NAME} has one instance if needed."
echo "EC2 boot, image pull, model download and model loading can take several minutes."
echo "Check progress with:"
echo "  ${SCRIPT_DIR}/ecs-status.sh ${profile}"
