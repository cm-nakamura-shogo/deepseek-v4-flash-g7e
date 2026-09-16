resource "aws_lb" "vllm" {
  name               = substr("${local.name_prefix}-vllm", 0, 32)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [for subnet in aws_subnet.private : subnet.id]

  enable_deletion_protection = false
  idle_timeout               = 300

  tags = {
    Name = "${local.name_prefix}-vllm"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.vllm.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = module.serving_profile[local.default_serving_profile].target_group_arn
  }
}

resource "aws_lb_listener_rule" "serving_profile" {
  for_each = {
    for profile_name, profile in local.serving_profiles :
    profile_name => profile
    if length(profile.route_header_values) > 0
  }

  listener_arn = aws_lb_listener.http.arn
  priority     = each.value.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = module.serving_profile[each.key].target_group_arn
  }

  condition {
    http_header {
      http_header_name = "X-LLM-Profile"
      values           = each.value.route_header_values
    }
  }
}
