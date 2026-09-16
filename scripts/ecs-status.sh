#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ecs-common.sh"

usage() {
  echo "Usage: $0 <profile|all>" >&2
  echo "Profiles: $(profile_names)" >&2
}

show_profile_status() {
  local profile="$1"

  configure_profile "${profile}"
  echo
  show_profile_context

  echo "ECS service"
  aws ecs describe-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --query 'services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount,taskDefinition:taskDefinition}' \
    --output table

  echo "GPU Auto Scaling group"
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${ASG_NAME}" \
    --query 'AutoScalingGroups[0].{min:MinSize,max:MaxSize,desired:DesiredCapacity,instances:Instances[].{id:InstanceId,state:LifecycleState,health:HealthStatus}}' \
    --output json

  echo "Recent ECS events"
  aws ecs describe-services \
    --cluster "${ECS_CLUSTER_NAME}" \
    --services "${ECS_SERVICE_NAME}" \
    --query 'services[0].events[0:5].[createdAt,message]' \
    --output table
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

target="$1"
if [[ "${target}" != "all" ]]; then
  require_profile "${target}"
fi

require_aws_identity
show_base_context

if [[ "${target}" == "all" ]]; then
  for profile in $(profile_names); do
    show_profile_status "${profile}"
  done
else
  show_profile_status "${target}"
fi
