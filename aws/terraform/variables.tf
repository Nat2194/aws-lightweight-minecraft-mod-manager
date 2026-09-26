variable "aws_region" {
  description = "The AWS region to deploy into"
  default     = "eu-west-1" # To be updated
}

variable "instance_type" {
  description = "ARM64 instance type (t4g.small = 2 vCPU, 2GB RAM | t4g.medium = 2 vCPU, 4GB RAM)"
  default     = "t4g.small" 
}

variable "admin_ip" {
  description = "TODO: to update with admin public IPs"
  default     = "0.0.0.0/0" 
}

variable "curseforge_project_id" {
  description = "The CurseForge ID for the modpack/mods"
  type        = string
}

variable "s3_bucket" {
  description = "The bucket holding persistent world saves"
  type        = string
}