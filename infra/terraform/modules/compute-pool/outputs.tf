output "autoscaling_group_name" {
  value = aws_autoscaling_group.this.name
}

output "capacity_provider_name" {
  value = aws_ecs_capacity_provider.this.name
}

output "launch_template_id" {
  value = aws_launch_template.this.id
}
