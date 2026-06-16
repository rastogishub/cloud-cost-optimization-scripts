# =============================================================
# Cloud Cost Optimization - Variables
# =============================================================

variable "environment" {
  description = "Deployment environment: dev | uat | prod"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "location_short" {
  description = "Short region code"
  type        = string
  default     = "eus"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID to audit"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region for cost tooling"
  type        = string
  default     = "us-east-1"
}

variable "cost_center" {
  description = "Cost center for billing"
  type        = string
}

variable "team_owner" {
  description = "Team responsible for cost optimisation"
  type        = string
  default     = "FinOps-CloudOps-Team"
}

variable "cost_alert_email" {
  description = "Email to receive cost alerts and budget notifications"
  type        = string
}

variable "aws_monthly_budget_usd" {
  description = "Monthly AWS spend threshold in USD before alerts fire"
  type        = number
  default     = 5000
}
