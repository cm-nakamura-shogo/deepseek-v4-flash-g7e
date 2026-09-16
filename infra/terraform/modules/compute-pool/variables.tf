variable "name_prefix" {
  description = "Prefix shared by all PoC resources."
  type        = string
}

variable "resource_suffix" {
  description = "Stable suffix used for AWS resource names."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type used by this compute pool."
  type        = string
}

variable "ecs_gpu_ami_id" {
  description = "Pinned ECS-optimized GPU AMI ID."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster joined by instances in this pool."
  type        = string
}

variable "instance_profile_arn" {
  description = "IAM instance profile ARN for ECS container instances."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups attached to pool instances."
  type        = list(string)
}

variable "subnet_ids" {
  description = "Private subnets in which the ASG may launch instances."
  type        = list(string)
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root volume size."
  type        = number
}

variable "max_size" {
  description = "Maximum number of instances in the PoC pool."
  type        = number
  default     = 1
}

variable "common_tags" {
  description = "Tags propagated to instances and root volumes."
  type        = map(string)
}
