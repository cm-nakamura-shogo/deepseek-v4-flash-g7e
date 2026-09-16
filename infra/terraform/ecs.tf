resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/ecs/${local.name_prefix}/exec"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_log_group_name     = aws_cloudwatch_log_group.ecs_exec.name
        cloud_watch_encryption_enabled = false
      }
    }
  }
}

module "serving_profile" {
  for_each = local.serving_profiles

  source = "./modules/serving-profile"

  name_prefix             = local.name_prefix
  resource_suffix         = each.value.resource_suffix
  task_execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn           = aws_iam_role.vllm_task.arn
  container_image         = each.value.container_image
  container_entry_point   = each.value.container_entry_point
  container_command       = each.value.container_command
  container_environment   = each.value.container_environment
  container_secrets       = local.container_secrets
  gpu_count               = each.value.gpu_count
  task_cpu                = each.value.task_cpu
  task_memory_mib         = each.value.task_memory_mib
  container_port          = var.container_port
  aws_region              = var.aws_region
  log_retention_days      = var.log_retention_days
  vpc_id                  = aws_vpc.main.id
  depends_on              = [aws_iam_role_policy_attachment.task_execution]
}

# Keep Service orchestration at the root because it joins three independently
# managed concerns: the Serving Profile, its Compute Pool and ALB routing.
# AWS requires the target group to be attached to a listener before CreateService.
resource "aws_ecs_service" "serving_profile" {
  for_each = local.serving_profiles

  name            = "${local.name_prefix}-${each.value.resource_suffix}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = module.serving_profile[each.key].task_definition_arn
  desired_count   = 0

  enable_execute_command            = true
  health_check_grace_period_seconds = 1800
  wait_for_steady_state             = false

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  capacity_provider_strategy {
    capacity_provider = module.compute_pool[each.value.compute_pool].capacity_provider_name
    base              = 0
    weight            = 1
  }

  network_configuration {
    assign_public_ip = false
    subnets          = [for subnet in aws_subnet.private : subnet.id]
    security_groups  = [aws_security_group.vllm_task.id]
  }

  load_balancer {
    target_group_arn = module.serving_profile[each.key].target_group_arn
    container_name   = "vllm"
    container_port   = var.container_port
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_iam_role_policy_attachment.task_execution,
    aws_lb_listener.http,
    aws_lb_listener_rule.serving_profile,
  ]

  lifecycle {
    ignore_changes = [desired_count]
  }
}

check "serving_profile_compute_pools" {
  assert {
    condition = alltrue([
      for profile in values(local.serving_profiles) :
      contains(keys(local.compute_pools), profile.compute_pool)
    ])
    error_message = "Every serving profile must reference an existing compute pool."
  }
}

check "serving_profile_gpu_capacity" {
  assert {
    condition = alltrue([
      for profile in values(local.serving_profiles) :
      profile.gpu_count <= local.compute_pools[profile.compute_pool].gpu_count
    ])
    error_message = "A serving profile cannot request more GPUs than its compute pool provides."
  }
}
