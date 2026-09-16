variable "name_prefix" {
  description = "Prefix shared by all PoC resources."
  type        = string
}

variable "resource_suffix" {
  description = "Stable suffix used for the Task Definition, Service, Target Group and log group."
  type        = string
}

variable "task_execution_role_arn" {
  description = "ECS task execution role ARN."
  type        = string
}

variable "task_role_arn" {
  description = "Runtime task role ARN."
  type        = string
}

variable "container_image" {
  description = "Immutable container image reference."
  type        = string
}

variable "container_entry_point" {
  description = "Optional container entry point override."
  type        = list(string)
  default     = null
}

variable "container_command" {
  description = "Command arguments passed to the vLLM image entrypoint."
  type        = list(string)
}

variable "container_environment" {
  description = "Additional environment variables injected into the model container."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "container_secrets" {
  description = "Secrets injected into the vLLM container."
  type = list(object({
    name      = string
    valueFrom = string
  }))
  default = []
}

variable "gpu_count" {
  description = "Number of GPUs reserved by each task."
  type        = number
}

variable "task_cpu" {
  description = "CPU units reserved by each task."
  type        = number
}

variable "task_memory_mib" {
  description = "Memory in MiB reserved by each task."
  type        = number
}

variable "container_port" {
  description = "vLLM API port."
  type        = number
}

variable "aws_region" {
  description = "AWS Region used by CloudWatch Logs."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period."
  type        = number
}

variable "vpc_id" {
  description = "VPC containing the IP target group."
  type        = string
}
