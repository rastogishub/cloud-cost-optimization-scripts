# =============================================================
# Cloud Cost Optimization Scripts - Infrastructure
# Author : Shubham Rastogi
# Automates identification of idle / oversized resources
# Strategy that contributed to $1M+ OPEX savings for enterprises.
# =============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------
# Resource Group for cost optimisation tooling
# ------------------------------------------------------------------
resource "azurerm_resource_group" "cost_ops" {
  name     = "rg-cost-ops-${var.environment}-${var.location_short}"
  location = var.location
  tags     = local.common_tags
}

# ------------------------------------------------------------------
# Azure Automation Account (runs cost audit runbooks)
# ------------------------------------------------------------------
resource "azurerm_automation_account" "cost_ops" {
  name                = "aa-cost-ops-${var.environment}-${var.location_short}"
  resource_group_name = azurerm_resource_group.cost_ops.name
  location            = var.location
  sku_name            = "Basic"
  tags                = local.common_tags

  identity {
    type = "SystemAssigned"
  }
}

# Grant Automation Account read access to audit the subscription
resource "azurerm_role_assignment" "automation_reader" {
  scope                = "/subscriptions/${var.azure_subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_automation_account.cost_ops.identity[0].principal_id
}

# ------------------------------------------------------------------
# Runbook: Find idle VMs (CPU < 5% for 7 days)
# ------------------------------------------------------------------
resource "azurerm_automation_runbook" "idle_vm_finder" {
  name                    = "Find-IdleVMs"
  resource_group_name     = azurerm_resource_group.cost_ops.name
  location                = var.location
  automation_account_name = azurerm_automation_account.cost_ops.name
  runbook_type            = "PowerShell"
  log_verbose             = false
  log_progress            = true
  description             = "Identifies VMs with < 5% CPU over 7 days and outputs cost-saving candidates"
  tags                    = local.common_tags

  content = <<-POWERSHELL
    <#
    .SYNOPSIS
        Finds idle Azure VMs based on CPU metrics.
    .DESCRIPTION
        Scans all VMs in the subscription and flags those with
        average CPU utilisation below the threshold for the lookback window.
    #>
    param(
        [double]$CpuThreshold   = 5.0,
        [int]$LookbackDays      = 7,
        [string]$SubscriptionId = ""
    )

    Connect-AzAccount -Identity | Out-Null

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }

    $EndTime   = (Get-Date).ToUniversalTime()
    $StartTime = $EndTime.AddDays(-$LookbackDays)

    $VMs = Get-AzVM -Status | Where-Object { $_.PowerState -eq "VM running" }

    $IdleVMs = foreach ($VM in $VMs) {
        $metrics = Get-AzMetric `
            -ResourceId $VM.Id `
            -MetricName "Percentage CPU" `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -AggregationType Average `
            -TimeGrain (New-TimeSpan -Hours 1) `
            -ErrorAction SilentlyContinue

        if ($metrics) {
            $avgCpu = ($metrics.Data | Measure-Object -Property Average -Average).Average
            if ($avgCpu -lt $CpuThreshold) {
                [PSCustomObject]@{
                    VMName         = $VM.Name
                    ResourceGroup  = $VM.ResourceGroupName
                    Location       = $VM.Location
                    VMSize         = $VM.HardwareProfile.VmSize
                    AvgCpuPercent  = [math]::Round($avgCpu, 2)
                    LookbackDays   = $LookbackDays
                    Recommendation = "Resize or deallocate - potential cost saving"
                }
            }
        }
    }

    if ($IdleVMs) {
        Write-Output "=== Idle VMs (CPU < $CpuThreshold% over $LookbackDays days) ==="
        $IdleVMs | Format-Table -AutoSize
        Write-Output "Total idle VMs found: $($IdleVMs.Count)"
    } else {
        Write-Output "No idle VMs found with CPU < $CpuThreshold% over the last $LookbackDays days."
    }
  POWERSHELL
}

# ------------------------------------------------------------------
# Runbook: Find unattached managed disks
# ------------------------------------------------------------------
resource "azurerm_automation_runbook" "orphan_disk_finder" {
  name                    = "Find-OrphanDisks"
  resource_group_name     = azurerm_resource_group.cost_ops.name
  location                = var.location
  automation_account_name = azurerm_automation_account.cost_ops.name
  runbook_type            = "PowerShell"
  log_verbose             = false
  log_progress            = true
  description             = "Finds unattached managed disks that are incurring unnecessary cost"
  tags                    = local.common_tags

  content = <<-POWERSHELL
    <#
    .SYNOPSIS
        Finds unattached managed disks across the subscription.
    #>
    param(
        [string]$SubscriptionId = ""
    )

    Connect-AzAccount -Identity | Out-Null

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    }

    $OrphanDisks = Get-AzDisk | Where-Object { $_.DiskState -eq "Unattached" }

    if ($OrphanDisks) {
        $Results = $OrphanDisks | Select-Object `
            Name, ResourceGroupName, Location, DiskSizeGB, Sku,
            @{ Name = "MonthlyCostEstimateUSD"; Expression = {
                # Rough estimate: Premium P10 (128 GB) ~ $19.71/mo
                # Adjust multiplier based on SKU in practice
                switch ($_.Sku.Name) {
                    "Premium_LRS"     { [math]::Round($_.DiskSizeGB * 0.154, 2) }
                    "StandardSSD_LRS" { [math]::Round($_.DiskSizeGB * 0.076, 2) }
                    default           { [math]::Round($_.DiskSizeGB * 0.040, 2) }
                }
            }}

        Write-Output "=== Unattached Managed Disks ==="
        $Results | Format-Table -AutoSize
        $TotalEstimate = ($Results | Measure-Object -Property MonthlyCostEstimateUSD -Sum).Sum
        Write-Output "Estimated monthly savings if deleted: `$$([math]::Round($TotalEstimate, 2)) USD"
    } else {
        Write-Output "No unattached managed disks found."
    }
  POWERSHELL
}

# ------------------------------------------------------------------
# Runbook: Find idle public IPs (unassociated)
# ------------------------------------------------------------------
resource "azurerm_automation_runbook" "orphan_pip_finder" {
  name                    = "Find-OrphanPublicIPs"
  resource_group_name     = azurerm_resource_group.cost_ops.name
  location                = var.location
  automation_account_name = azurerm_automation_account.cost_ops.name
  runbook_type            = "PowerShell"
  log_verbose             = false
  log_progress            = true
  description             = "Identifies unassociated Standard SKU public IPs costing ~$3.65/month each"
  tags                    = local.common_tags

  content = <<-POWERSHELL
    <#
    .SYNOPSIS
        Identifies reserved public IP addresses that are not associated
        with any resource (Standard SKU = ~$3.65/month each).
    #>

    Connect-AzAccount -Identity | Out-Null

    $OrphanPIPs = Get-AzPublicIpAddress | Where-Object {
        $_.IpConfiguration -eq $null -and $_.Sku.Name -eq "Standard"
    }

    if ($OrphanPIPs) {
        Write-Output "=== Unassociated Standard Public IPs ==="
        $OrphanPIPs | Select-Object Name, ResourceGroupName, Location, PublicIpAllocationMethod |
            Format-Table -AutoSize
        $MonthlyCost = $OrphanPIPs.Count * 3.65
        Write-Output "Estimated monthly savings if released: `$$MonthlyCost USD"
    } else {
        Write-Output "No unassociated Standard public IPs found."
    }
  POWERSHELL
}

# ------------------------------------------------------------------
# Schedule: Run cost audits weekly on Monday 06:00 UTC
# ------------------------------------------------------------------
resource "azurerm_automation_schedule" "weekly_monday" {
  name                    = "weekly-monday-0600"
  resource_group_name     = azurerm_resource_group.cost_ops.name
  automation_account_name = azurerm_automation_account.cost_ops.name
  frequency               = "Week"
  interval                = 1
  timezone                = "UTC"
  start_time              = "2025-01-06T06:00:00Z"
  week_days               = ["Monday"]
}

resource "azurerm_automation_job_schedule" "idle_vm_weekly" {
  resource_group_name     = azurerm_resource_group.cost_ops.name
  automation_account_name = azurerm_automation_account.cost_ops.name
  schedule_name           = azurerm_automation_schedule.weekly_monday.name
  runbook_name            = azurerm_automation_runbook.idle_vm_finder.name
}

resource "azurerm_automation_job_schedule" "orphan_disk_weekly" {
  resource_group_name     = azurerm_resource_group.cost_ops.name
  automation_account_name = azurerm_automation_account.cost_ops.name
  schedule_name           = azurerm_automation_schedule.weekly_monday.name
  runbook_name            = azurerm_automation_runbook.orphan_disk_finder.name
}

# ------------------------------------------------------------------
# AWS Cost Explorer Budget Alert (multi-cloud cost governance)
# ------------------------------------------------------------------
resource "aws_budgets_budget" "monthly_euc" {
  name         = "budget-euc-monthly-${var.environment}"
  budget_type  = "COST"
  limit_amount = tostring(var.aws_monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["Project$VDI-Migration"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.cost_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.cost_alert_email]
  }
}

# ------------------------------------------------------------------
# Locals
# ------------------------------------------------------------------
locals {
  common_tags = {
    Environment = var.environment
    Service     = "CostOptimization"
    ManagedBy   = "Terraform"
    Owner       = var.team_owner
    CostCenter  = var.cost_center
  }
}
