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
        Pre-installation checker for FLARE VM.

    .DESCRIPTION
        Runs all pre-installation checks and prints a color-coded report.
        Use this script to verify that your virtual machine satisfies every
        requirement before running install.ps1.

        Checks performed:
          - Running as Administrator (mandatory)
          - PowerShell version >= 5 (mandatory)
          - Execution policy Unrestricted (mandatory)
          - Windows version >= 10 (mandatory)
          - Windows build number is a tested release
          - Running inside a Virtual Machine
          - Username contains no spaces (mandatory)
          - Disk space >= 60 GB
          - RAM >= 4 GB
          - Internet connectivity to google.com, github.com, raw.githubusercontent.com (mandatory)
          - Windows Defender / Tamper Protection disabled

    .EXAMPLE
        .\preflight.ps1

        Description
        ---------------------------------------
        Run all pre-install checks and display the results.

    .LINK
        https://github.com/mandiant/flare-vm
#>

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper: print a pass / fail / warn line
# ---------------------------------------------------------------------------
function Write-CheckResult {
    param (
        [string]$label,
        [string]$errorInfo,
        [switch]$mandatory,
        [switch]$warn
    )
    if ($errorInfo) {
        $symbol = if ($mandatory) { "[FAIL]" } else { "[WARN]" }
        $color  = if ($mandatory) { "Red" } else { "Yellow" }
        Write-Host "  $symbol $label" -ForegroundColor $color
        Write-Host "         $errorInfo" -ForegroundColor $color
        return $false
    } else {
        Write-Host "  [ OK ] $label" -ForegroundColor Green
        return $true
    }
}

# ---------------------------------------------------------------------------
# Check functions
# ---------------------------------------------------------------------------
function Test-IsAdmin {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            return "Script is not running as Administrator"
        }
    } catch {
        return "Unable to determine if running as Administrator"
    }
}

function Test-PSVersionCompat {
    try {
        $psVersion = $PSVersionTable.PSVersion
        if ($psVersion -lt [System.Version]"5.0.0") {
            return "PowerShell $psVersion is not supported (need >= 5)"
        }
    } catch {
        return "Unable to determine PowerShell version"
    }
}

function Test-ExecutionPolicyUnrestricted {
    try {
        if ((Get-ExecutionPolicy).ToString() -ne "Unrestricted") {
            return "Execution policy is not Unrestricted. Run: Set-ExecutionPolicy Unrestricted -Force"
        }
    } catch {
        return "Unable to determine PowerShell execution policy"
    }
}

function Test-WindowsVersionCompat {
    try {
        $osMajor = (Get-CimInstance -Class Win32_OperatingSystem).Version.Split('.')[0]
        if ([int]$osMajor -lt 10) {
            return "Windows version $osMajor is not supported (need >= 10)"
        }
    } catch {
        return "Unable to determine Windows version"
    }
}

function Test-TestedWindowsBuild {
    $testedBuilds = @(19045, 20348, 26100)
    try {
        $build = [int](Get-CimInstance -Class Win32_OperatingSystem).BuildNumber
        if ($build -notin $testedBuilds) {
            return "Build $build has not been tested. Tested builds: $($testedBuilds -join ', ')"
        }
    } catch {
        return "Unable to determine Windows build number"
    }
}

function Test-IsVirtualMachine {
    $virtualModels = @('VirtualBox', 'VMware', 'Virtual Machine', 'Hyper-V')
    try {
        $model = (Get-CimInstance Win32_ComputerSystem).Model
        $isVm = $false
        foreach ($vm in $virtualModels) {
            if ($model.Contains($vm)) { $isVm = $true; break }
        }
        if (-not $isVm) {
            return "Not running in a recognised VM (model: $model)"
        }
    } catch {
        return "Unable to determine if running in a VM"
    }
}

function Test-UsernameNoSpaces {
    try {
        if (${Env:UserName} -match '\s') {
            return "Username '${Env:UserName}' contains spaces which will break installation"
        }
    } catch {
        return "Unable to read username"
    }
}

function Test-DiskSpace {
    try {
        $disk = Get-PSDrive (Get-Location).Drive.Name
        if (-not (($disk.Used + $disk.Free) / 1GB -gt 58.8)) {
            $freeGB = [math]::Round($disk.Free / 1GB, 1)
            return "Only ${freeGB} GB free; at least 60 GB total disk size is preferred"
        }
    } catch {
        return "Unable to determine disk space"
    }
}

function Test-EnoughRAM {
    try {
        $ramGB = (Get-CimInstance -Class Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
        if ($ramGB -lt 4) {
            return "Only $([math]::Round($ramGB, 1)) GB RAM; at least 4 GB is recommended"
        }
    } catch {
        return "Unable to determine RAM capacity"
    }
}

function Test-InternetConnectivity {
    $hosts = @('google.com', 'github.com', 'raw.githubusercontent.com')
    foreach ($h in $hosts) {
        if (-not (Test-Connection $h -Quiet -Count 1)) {
            return "Cannot reach $h - check network settings"
        }
        try {
            $r = Invoke-WebRequest -Uri "https://$h" -UseBasicParsing -DisableKeepAlive -ErrorAction Stop
            if ($r.StatusCode -ne 200) {
                return "Unexpected HTTP $($r.StatusCode) from $h"
            }
        } catch {
            return "HTTP request to $h failed: $($_.Exception.Message)"
        }
    }
}

function Test-DefenderDisabled {
    try {
        $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq "Running") {
            return "Windows Defender is running - disable via Group Policy before installing"
        }
        $tp = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" `
            -Name "TamperProtection" -ErrorAction Stop
        if ($tp.TamperProtection -eq 5) {
            return "Tamper Protection is enabled - disable it and reboot before installing"
        }
    } catch {
        return "Unable to determine Defender / Tamper Protection status"
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  FLARE-VM Pre-Installation Checker" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$allMandatoryPassed = $true
$allChecksPassed    = $true

# Mandatory checks
$checks = @(
    @{ Label="Running as Administrator";         Fn={ Test-IsAdmin };                   Mandatory=$true  },
    @{ Label="PowerShell version >= 5";          Fn={ Test-PSVersionCompat };            Mandatory=$true  },
    @{ Label="Execution policy Unrestricted";    Fn={ Test-ExecutionPolicyUnrestricted }; Mandatory=$true  },
    @{ Label="Windows version >= 10";            Fn={ Test-WindowsVersionCompat };       Mandatory=$true  },
    @{ Label="Username has no spaces";           Fn={ Test-UsernameNoSpaces };           Mandatory=$true  },
    @{ Label="Internet connectivity";            Fn={ Test-InternetConnectivity };       Mandatory=$true  },
    @{ Label="Tested Windows build";             Fn={ Test-TestedWindowsBuild };         Mandatory=$false },
    @{ Label="Running in a Virtual Machine";     Fn={ Test-IsVirtualMachine };           Mandatory=$false },
    @{ Label="Disk space >= 60 GB";              Fn={ Test-DiskSpace };                  Mandatory=$false },
    @{ Label="RAM >= 4 GB";                      Fn={ Test-EnoughRAM };                  Mandatory=$false },
    @{ Label="Windows Defender disabled";        Fn={ Test-DefenderDisabled };           Mandatory=$false }
)

foreach ($check in $checks) {
    $result = & $check.Fn
    $passed = Write-CheckResult -label $check.Label -errorInfo $result -mandatory:$check.Mandatory
    if (-not $passed) {
        if ($check.Mandatory) { $allMandatoryPassed = $false }
        $allChecksPassed = $false
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan

if ($allMandatoryPassed -and $allChecksPassed) {
    Write-Host "  All checks passed - ready to install!" -ForegroundColor Green
} elseif ($allMandatoryPassed) {
    Write-Host "  Mandatory checks passed - warnings present." -ForegroundColor Yellow
    Write-Host "  Review warnings above before continuing." -ForegroundColor Yellow
} else {
    Write-Host "  One or more MANDATORY checks failed." -ForegroundColor Red
    Write-Host "  Resolve the failures above before running install.ps1." -ForegroundColor Red
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
