output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}
