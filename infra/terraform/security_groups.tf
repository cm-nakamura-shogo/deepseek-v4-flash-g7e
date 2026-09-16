resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Ingress to the internal vLLM ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from approved VPC clients; replace with VPC Link SG later"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  egress {
    description = "Forward traffic to ECS tasks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_security_group" "ecs_instance" {
  name_prefix = "${local.name_prefix}-ecs-instance-"
  description = "ECS GPU container instances; no inbound administration ports"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Outbound through NAT for registries and model downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ecs-instance"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "vllm_task" {
  name_prefix = "${local.name_prefix}-vllm-task-"
  description = "vLLM ECS task traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "vLLM API from the internal ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Registries, Hugging Face, CloudWatch and SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-vllm-task"
  }

  lifecycle {
    create_before_destroy = true
  }
}
