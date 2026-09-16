#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/ecs-common.sh"

usage() {
  echo "Usage: $0 <profile|all>" >&2
  echo "Profiles: $(profile_names)" >&2
}

wait_for_service_stop() {
  local service_name="$1"
  local deadline counts running_count pending_count

  deadline=$((SECONDS + 900))
  while true; do
    counts="$(aws ecs describe-services \
      --cluster "${ECS_CLUSTER_NAME}" \
      --services "${service_name}" \
      --query 'services[0].[runningCount,pendingCount]' \
      --output text)"
    running_count="${counts%%$'\t'*}"
    pending_count="${counts##*$'\t'}"

    if [[ "${running_count}" == "0" && "${pending_count}" == "0" ]]; then
      return
    fi

    if (( SECONDS >= deadline )); then
      echo "Timed out before tasks stopped for ${service_name}." >&2
      return 1
    fi

    echo "Tasks still stopping for ${service_name}: running=${running_count}, pending=${pending_count}"
    sleep 15
  done
}

wait_for_pool_empty() {
  local asg_name="$1"
  local deadline instance_count

  deadline=$((SECONDS + 900))
  while true; do
    instance_count="$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "${asg_name}" \
      --query 'length(AutoScalingGroups[0].Instances)' \
      --output text)"

    if [[ "${instance_count}" == "0" ]]; then
      return
    fi

    if (( SECONDS >= deadline )); then
      echo "Timed out while waiting for ${asg_name} to terminate its instances." >&2
      return 1
    fi

    echo "Waiting for ${asg_name} instances to terminate: count=${instance_count}"
    sleep 15
  done
}

stop_profile() {
  local profile="$1"
  local service_name compute_pool_name asg_name

  configure_profile "${profile}"
  service_name="$(profile_service_name "${profile}")"
  compute_pool_name="$(profile_pool_name "${profile}")"
  asg_name="$(pool_asg_name "${compute_pool_name}")"
  echo
  show_profile_context
  echo "Setting ECS service desired count to 0..."
  aws ecs update-service \
    --cluster "${ECS_CLUSTER_NAME}" \
    --service "${service_name}" \
    --desired-count 0 \
    --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount}' \
    --output table

  wait_for_service_stop "${service_name}"

  if pool_has_active_services "${compute_pool_name}"; then
    echo "Compute Pool ${compute_pool_name} still has an active serving profile; ASG is unchanged."
    return
  fi

  echo "No active profile remains on ${compute_pool_name}. Setting ${asg_name} desired capacity to 0..."
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "${asg_name}" \
    --desired-capacity 0 \
    --no-honor-cooldown

  wait_for_pool_empty "${asg_name}"
  echo "Compute Pool ${compute_pool_name} is empty."
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
    stop_profile "${profile}"
  done
else
  stop_profile "${target}"
fi

echo
echo "Scale-in terminates EC2 instances and deletes their root EBS volumes and model caches."
echo "NAT Gateway, ALB, ECR and CloudWatch Logs remain provisioned and billable."
