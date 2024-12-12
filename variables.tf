variable "region" {
  description = "The aws region. Choose the one closest to you: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html#concepts-available-regions"
  type        = string
}

variable "resource_name" {
  description = "Name with which to prefix resources in AWS"
  type        = string
  default     = "cloud-gaming"
}

variable "allowed_availability_zone_identifier" {
  description = "The allowed availability zone identify (the letter suffixing the region). Choose ones that allows you to request the desired instance as spot instance in your region. If omitted, an availability zone will be selected at random and the instance will be booted in it."
  type        = list(string)
  default     = []
}

variable "instance_type" {
  description = "The aws instance type, Choose one with a CPU/GPU that fits your need: https://aws.amazon.com/ec2/instance-types/#Accelerated_Computing"
  type        = string
  default     = "g4dn.xlarge"
}

variable "root_block_device_size_gb" {
  description = "The size of the root block device (C:\\ drive) attached to the instance"
  type        = number
  default     = 120
}

variable "custom_ami" {
  description = "Use the specified AMI instead of the most recent windows AMI in available in the region"
  type        = string
  default     = ""
}

variable "skip_install" {
  description = "Skip installation step on startup. Useful when using a custom AMI that is already setup"
  type        = bool
  default     = false
}

variable "custom_software" {
  description = "Download and install software on first login"
  type        = object({
    parsec = bool
    auto_login = bool
    gpu_driver = bool
  })
  default     = {
    parsec = true
    auto_login = true
    gpu_driver = true
  }
}

variable "firewall_rules" {
  description = "Specify which firewall rules to apply"
  type        = object({
    rdp = bool
    vnc = bool
    sunshine = bool
  })
  default     = {
    rdp = true
    vnc = false
    sunshine = false
  }
}

variable "choco_packages" {
  description = "Download and install choco packages on first login"
  type        = list(string)
  default     = ["steam"]
  #"steam", "goggalaxy", "uplay", "origin", "epicgameslauncher"
}
