resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}/${var.resource_suffix}"
  retention_in_days = var.log_retention_days
}

resource "aws_lb_target_group" "this" {
  name        = trim(substr("${var.name_prefix}-${var.resource_suffix}", 0, 32), "-")
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 60

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 10
  }

  tags = {
    Name = "${var.name_prefix}-${var.resource_suffix}"
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.resource_suffix}"
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  ipc_mode                 = "host"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory_mib)
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name      = "model-cache"
    host_path = "/var/lib/llm-model-cache"
  }

  container_definitions = jsonencode([
    merge({
      name      = "vllm"
      image     = var.container_image
      essential = true
      command   = var.container_command

      resourceRequirements = [
        {
          type  = "GPU"
          value = tostring(var.gpu_count)
        }
      ]

      portMappings = [
        {
          name          = "vllm-http"
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      mountPoints = [
        {
          sourceVolume  = "model-cache"
          containerPath = "/root/.cache/huggingface"
          readOnly      = false
        }
      ]

      environment = concat([
        {
          name  = "HF_HOME"
          value = "/root/.cache/huggingface"
        },
        {
          name  = "VLLM_NO_USAGE_STATS"
          value = "1"
        }
      ], var.container_environment)

      secrets = var.container_secrets

      linuxParameters = {
        initProcessEnabled = true
      }

      stopTimeout = 120

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "vllm"
        }
      }
      }, var.container_entry_point == null ? {} : {
      entryPoint = var.container_entry_point
    })
  ])
}
