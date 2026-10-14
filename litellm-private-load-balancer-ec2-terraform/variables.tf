# Variables
variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "key_pair_name" {
  description = "The name of the key pair to use for SSH access"
  type        = string
}
variable "ssh_allowed_cidrs" {
  description = "CIDR ranges allowed to SSH to the instance. Empty (the default) opens no SSH; use SSM Session Manager instead."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.ssh_allowed_cidrs : can(cidrhost(c, 0)) && !contains(["0.0.0.0/0", "::/0"], c)
    ])
    error_message = "ssh_allowed_cidrs must be valid CIDR ranges and must not include 0.0.0.0/0 or ::/0."
  }
}
