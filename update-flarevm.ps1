<#
 Copyright 2017 Google LLC

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
#>

<#
    .SYNOPSIS
        Update script for FLARE VM.

    .DESCRIPTION
        Upgrades all installed FLARE VM and Chocolatey packages to the latest available versions.
        Packages that fail to upgrade are reported at the end of the run without halting the process.

    .PARAMETER source
        Additional NuGet source URL. Defaults to the standard vm-packages MyGet feed.

    .PARAMETER logPath
        Path for the update log file. Defaults to C:\flare-vm\update.log.

    .EXAMPLE
        .\update-flarevm.ps1

        Description
        ---------------------------------------
        Upgrade all installed FLARE VM packages.

    .EXAMPLE
        .\update-flarevm.ps1 -source "https://custom.feed/api/v2"

        Description
        ---------------------------------------
        Upgrade packages using an additional custom feed.

    .LINK
        https://github.com/mandiant/flare-vm
        https://github.com/mandiant/VM-Packages
#>

param (
    [string]$source = $null,
    [string]$logPath = "C:\flare-vm\update.log"
)

$ErrorActionPreference = 'Stop'

function Write-UpdateLog {
    param (
        [string]$message,
        [string]$level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$level] $message"
    try {
        $logDir = Split-Path $logPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        Add-Content -Path $logPath -Value $logEntry -Encoding UTF8
    } catch {
        # Silently continue if logging is unavailable
    }
}

# Ensure running as Administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[!] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

# Ensure Chocolatey is available
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "[!] Chocolatey is not installed. Cannot update packages." -ForegroundColor Red
    exit 1
}

Write-Host "[+] Starting FLARE-VM update..." -ForegroundColor Cyan
Write-UpdateLog "Starting FLARE-VM update"

# Build choco sources argument
$vmPackagesSource = "https://www.myget.org/F/vm-packages/api/v2"
$sources = $vmPackagesSource
if (-not [string]::IsNullOrEmpty($source)) {
    $sources = "$source;$vmPackagesSource"
}

# Retrieve list of installed packages
Write-Host "[+] Retrieving installed packages..." -ForegroundColor Cyan
$installedRaw = choco list --local-only -r 2>$null
$installedPackages = $installedRaw | ForEach-Object {
    $parts = $_ -split '\|'
    [PSCustomObject]@{ Name = $parts[0]; Version = $parts[1] }
}

Write-Host "[+] Found $($installedPackages.Count) installed packages" -ForegroundColor Green
Write-UpdateLog "Found $($installedPackages.Count) installed packages"

# Upgrade each package individually so failures are isolated
$upgraded = @()
$failed = @()
$skipped = @()
$total = $installedPackages.Count
$current = 0

foreach ($pkg in $installedPackages) {
    $current++
    $percentComplete = [int](($current - 1) / $total * 100)
    Write-Progress -Activity "Upgrading FLARE-VM packages" `
        -Status "[$current/$total] $($pkg.Name)" `
        -PercentComplete $percentComplete

    try {
        Write-Host "[+] Upgrading $($pkg.Name) ($($pkg.Version))..." -ForegroundColor Cyan
        $output = choco upgrade $pkg.Name -y --no-progress -s $sources 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Detect if package was actually upgraded or already current
            if ($output -match "already the latest version") {
                $skipped += $pkg.Name
                Write-Host "`t[-] $($pkg.Name) is already up-to-date" -ForegroundColor Gray
                Write-UpdateLog "UP-TO-DATE: $($pkg.Name)"
            } else {
                $upgraded += $pkg.Name
                Write-Host "`t[+] $($pkg.Name) upgraded" -ForegroundColor Green
                Write-UpdateLog "UPGRADED: $($pkg.Name)"
            }
        } else {
            throw "choco exited with code $LASTEXITCODE"
        }
    } catch {
        $failed += $pkg.Name
        Write-Host "`t[!] Failed to upgrade $($pkg.Name): $_" -ForegroundColor Red
        Write-UpdateLog "FAILED: $($pkg.Name): $_" -level "ERROR"
    }
}

Write-Progress -Activity "Upgrading FLARE-VM packages" -Completed

# Display summary
Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " FLARE-VM Update Summary" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Upgraded    : $($upgraded.Count)" -ForegroundColor Green
Write-Host " Already current: $($skipped.Count)" -ForegroundColor Gray
Write-Host " Failed      : $($failed.Count)" -ForegroundColor Red
Write-Host "======================================" -ForegroundColor Cyan
Write-Host " Log: $logPath" -ForegroundColor Cyan

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host " Failed packages:" -ForegroundColor Red
    foreach ($pkg in $failed) {
        Write-Host "   [X] $pkg" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host " Retry a failed package manually:" -ForegroundColor Yellow
    Write-Host "   choco upgrade -y <package_name>" -ForegroundColor Yellow
}

Write-UpdateLog "Update complete - Upgraded: $($upgraded.Count), Already current: $($skipped.Count), Failed: $($failed.Count)"
Write-Host ""
Write-Host "[+] Update complete." -ForegroundColor Green
