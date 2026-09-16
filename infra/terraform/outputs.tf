output "aws_region" {
  value = var.aws_region
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Legacy-compatible output for the default Nemotron service."
  value       = aws_ecs_service.serving_profile[local.default_serving_profile].name
}

output "autoscaling_group_name" {
  description = "Legacy-compatible output for the default one-GPU pool."
  value       = module.compute_pool[local.default_compute_pool].autoscaling_group_name
}

output "compute_pools" {
  value = {
    for pool_name, pool in local.compute_pools : pool_name => {
      instance_type          = pool.instance_type
      gpu_count              = pool.gpu_count
      autoscaling_group_name = module.compute_pool[pool_name].autoscaling_group_name
      capacity_provider_name = module.compute_pool[pool_name].capacity_provider_name
    }
  }
}

output "serving_profiles" {
  value = {
    for profile_name, profile in local.serving_profiles : profile_name => {
      model_id            = profile.model_id
      compute_pool        = profile.compute_pool
      ecs_service_name    = aws_ecs_service.serving_profile[profile_name].name
      task_definition_arn = module.serving_profile[profile_name].task_definition_arn
      route_header_values = profile.route_header_values
    }
  }
}

output "internal_alb_dns_name" {
  value = aws_lb.vllm.dns_name
}

output "vllm_url" {
  value = "http://${aws_lb.vllm.dns_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.vllm.repository_url
}

output "pinned_ecs_gpu_ami" {
  value = {
    image_id   = var.ecs_gpu_ami_id
    image_name = "al2023-ami-ecs-gpu-hvm-2023.0.20260820-kernel-6.1-x86_64-ebs"
  }
}
