resource "aws_launch_template" "this" {
  name_prefix   = "${var.name_prefix}-${var.resource_suffix}-"
  image_id      = var.ecs_gpu_ami_id
  instance_type = var.instance_type

  update_default_version = true

  iam_instance_profile {
    arn = var.instance_profile_arn
  }

  vpc_security_group_ids = var.security_group_ids

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gib
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/ecs-user-data.sh.tftpl", {
    ecs_cluster_name = var.ecs_cluster_name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      Name = "${var.name_prefix}-${var.resource_suffix}"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.common_tags, {
      Name = "${var.name_prefix}-${var.resource_suffix}-root"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name = "${var.name_prefix}-${var.resource_suffix}"

  min_size         = 0
  max_size         = var.max_size
  desired_capacity = 0

  vpc_zone_identifier = var.subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(var.common_tags, {
      Name = "${var.name_prefix}-${var.resource_suffix}"
    })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # ECS Capacity Provider adds this tag automatically. Declare it explicitly
  # so a subsequent Terraform plan does not try to remove it.
  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "this" {
  name = "${var.name_prefix}-${var.resource_suffix}"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.this.arn
    managed_draining               = "ENABLED"
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
      instance_warmup_period    = 300
    }
  }
}
