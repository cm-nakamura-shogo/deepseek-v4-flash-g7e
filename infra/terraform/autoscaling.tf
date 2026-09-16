module "compute_pool" {
  for_each = local.compute_pools

  source = "./modules/compute-pool"

  name_prefix          = local.name_prefix
  resource_suffix      = each.value.resource_suffix
  instance_type        = each.value.instance_type
  ecs_gpu_ami_id       = var.ecs_gpu_ami_id
  ecs_cluster_name     = aws_ecs_cluster.main.name
  instance_profile_arn = aws_iam_instance_profile.ecs.arn
  security_group_ids   = [aws_security_group.ecs_instance.id]
  subnet_ids           = [for subnet in aws_subnet.private : subnet.id]
  root_volume_size_gib = each.value.root_volume_size_gib
  max_size             = each.value.max_size
  common_tags          = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = [
    for pool_name in sort(keys(local.compute_pools)) :
    module.compute_pool[pool_name].capacity_provider_name
  ]

  default_capacity_provider_strategy {
    capacity_provider = module.compute_pool[local.default_compute_pool].capacity_provider_name
    base              = 0
    weight            = 1
  }
}
