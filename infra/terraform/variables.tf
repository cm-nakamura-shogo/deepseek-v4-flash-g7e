variable "aws_account_id" {
  description = "AWS account ID allowed for this PoC."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "aws_region" {
  description = "AWS Region for all resources."
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Base name used for resources."
  type        = string
  default     = "self-hosted-llm"
}

variable "environment" {
  description = "Environment name appended to resource names."
  type        = string
  default     = "poc"
}

variable "availability_zones" {
  description = "Two AZs used by the internal ALB. G7e is offered in both as of 2026-08-28."
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]

  validation {
    condition     = length(var.availability_zones) == 2 && var.availability_zones[0] != var.availability_zones[1]
    error_message = "availability_zones must contain exactly two distinct AZs."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the isolated PoC VPC."
  type        = string
  default     = "10.20.0.0/20"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR for the single PoC NAT Gateway."
  type        = string
  default     = "10.20.0.0/24"
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs for the internal ALB and ECS tasks."
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "private_subnet_cidrs must contain exactly two CIDRs."
  }
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to call the internal ALB. Restrict this to the VPC Link security group when API Gateway is added."
  type        = list(string)
  default     = ["10.20.0.0/20"]
}

variable "ecs_gpu_ami_id" {
  description = "Pinned ECS-optimized Amazon Linux 2023 GPU AMI. Update deliberately after validation."
  type        = string
  default     = "ami-017b6c4af9d973664"

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ecs_gpu_ami_id))
    error_message = "ecs_gpu_ami_id must be an AMI ID."
  }
}

variable "huggingface_token_secret_arn" {
  description = "Optional Secrets Manager secret ARN containing HF_TOKEN. The secret value is never managed by Terraform."
  type        = string
  default     = null
}

variable "container_port" {
  description = "vLLM OpenAI-compatible API port."
  type        = number
  default     = 8000
}

variable "deepseek_v4_flash_max_num_batched_tokens" {
  description = "Maximum scheduler token budget for the DeepSeek V4 Flash serving profile."
  type        = number
  default     = 4096

  validation {
    condition = contains(
      [2048, 4096, 8192, 16384],
      var.deepseek_v4_flash_max_num_batched_tokens,
    )
    error_message = "deepseek_v4_flash_max_num_batched_tokens must be one of 2048, 4096, 8192 or 16384."
  }
}

variable "deepseek_v4_flash_enable_prefill_compilation" {
  description = "Enable the experimental vLLM compile and piecewise CUDA Graph configuration; vLLM 0.26.0 warns that DeepSeek V4 does not support torch.compile."
  type        = bool
  default     = false
}

variable "deepseek_v4_flash_mtp_speculative_tokens" {
  description = "Number of MTP speculative tokens for the DeepSeek V4 Flash serving profile; zero disables speculative decoding."
  type        = number
  default     = 1

  validation {
    condition = contains(
      [0, 1, 2, 3],
      var.deepseek_v4_flash_mtp_speculative_tokens,
    )
    error_message = "deepseek_v4_flash_mtp_speculative_tokens must be 0, 1, 2 or 3."
  }

  validation {
    condition = !(
      var.deepseek_v4_flash_mtp_speculative_tokens > 0 &&
      var.deepseek_v4_flash_enable_prefill_compilation
    )
    error_message = "MTP speculative decoding and the experimental prefill compilation switch must not be enabled together."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Additional tags merged into all resources."
  type        = map(string)
  default     = {}
}
