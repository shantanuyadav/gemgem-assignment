# --- General ---

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  description = "Used in resource naming"
  type        = string
  default     = "ecs-production"
}

variable "environment" {
  type    = string
  default = "production"
}

# --- Networking (existing VPC resources) ---

variable "vpc_id" {
  description = "VPC to deploy into"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for ECS instances — need at least 2 for HA"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Need at least 2 private subnets in different AZs."
  }
}

variable "public_subnet_ids" {
  description = "Public subnets for the ALB"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Need at least 2 public subnets for the ALB."
  }
}

variable "alb_security_group_id" {
  description = "SG for the ALB (inbound 443/80)"
  type        = string
}

variable "ecs_instance_security_group_id" {
  description = "SG for ECS instances (ALB -> ephemeral ports)"
  type        = string
}

# --- ECS ---

variable "container_port" {
  type    = number
  default = 80
}

variable "service_desired_count" {
  description = "Initial desired task count"
  type        = number
  default     = 3
}

variable "task_cpu" {
  description = "CPU units (1 vCPU = 1024)"
  type    = number
  default = 256
}

variable "task_memory" {
  description = "MiB"
  type    = number
  default = 512
}

# --- ASG ---

variable "instance_types" {
  description = "Instance types for the mixed instances policy (order matters)"
  type        = list(string)
  default     = ["t3.medium", "t3a.medium", "t3.large"]
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 10
}

variable "asg_on_demand_base" {
  description = "On-demand baseline count"
  type        = number
  default     = 2
}

variable "asg_on_demand_percentage_above_base" {
  description = "% on-demand above the base (0 = all spot above base)"
  type    = number
  default = 0
}

variable "ecs_ami_id" {
  description = "ECS-optimized AMI. Leave blank to auto-detect latest."
  type    = string
  default = ""
}

variable "instance_key_name" {
  description = "Key pair for SSH. Leave empty to disable."
  type    = string
  default = ""
}

# --- Capacity Provider ---

variable "capacity_provider_target_capacity" {
  description = "Target utilization pct for managed scaling"
  type        = number
  default     = 100
}

# --- Service Auto Scaling ---

variable "service_min_count" {
  type    = number
  default = 2
}

variable "service_max_count" {
  type    = number
  default = 20
}

variable "service_cpu_target" {
  description = "Target CPU % for scaling"
  type    = number
  default = 60
}

# --- Secrets ---

variable "ssm_parameter_arns" {
  description = "Map of SSM param ARNs the task needs. Keys = env var names, values = ARNs. Actual secret values should be pre-provisioned outside terraform."
  type        = map(string)
  default = {
    "app_secret_key" = "arn:aws:ssm:us-east-1:ACCOUNT_ID:parameter/production/app/secret_key"
    "db_password"    = "arn:aws:ssm:us-east-1:ACCOUNT_ID:parameter/production/app/db_password"
  }
}

# --- ALB / health checks ---

variable "health_check_path" {
  type    = string
  default = "/"
}

variable "health_check_interval" {
  type    = number
  default = 15
}

variable "health_check_healthy_threshold" {
  type    = number
  default = 2
}

variable "health_check_unhealthy_threshold" {
  type    = number
  default = 3
}

variable "deregistration_delay" {
  description = "How long the ALB waits for in-flight requests before deregistering"
  type    = number
  default = 120
}

variable "alb_certificate_arn" {
  description = "ACM cert ARN for HTTPS. Leave blank for HTTP-only (dev)."
  type    = string
  default = ""
}
