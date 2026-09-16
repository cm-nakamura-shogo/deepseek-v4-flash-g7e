#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ecs-common.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <profile>" >&2
  echo "Profiles: $(profile_names)" >&2
  exit 2
fi

configure_profile "$1"
require_aws_identity
require_command session-manager-plugin

task_arn="$(aws ecs list-tasks \
  --cluster "${ECS_CLUSTER_NAME}" \
  --service-name "${ECS_SERVICE_NAME}" \
  --desired-status RUNNING \
  --query 'taskArns[0]' \
  --output text)"

if [[ -z "${task_arn}" || "${task_arn}" == "None" ]]; then
  echo "No running task found for ${ACTIVE_PROFILE} (${ECS_SERVICE_NAME})." >&2
  exit 1
fi

aws ecs execute-command \
  --cluster "${ECS_CLUSTER_NAME}" \
  --task "${task_arn}" \
  --container vllm \
  --interactive \
  --command "/bin/bash"
