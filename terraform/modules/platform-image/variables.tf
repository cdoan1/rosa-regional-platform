variable "resource_name_base" {
  description = "Base name for all resources (e.g., 'regional-x8k2')"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
