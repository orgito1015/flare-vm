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
        Pre-installation preparation script for FLARE-VM.

    .DESCRIPTION
        Disables or configures all Windows settings that would otherwise block
        or interfere with a FLARE-VM installation:

          - Sets PowerShell Execution Policy to Unrestricted
          - Disables Windows Defender (real-time protection, behavior monitoring,
            cloud protection, sample submission, MAPS, scheduled tasks)
          - Attempts to disable Tamper Protection via the registry
            (NOTE: Tamper Protection must first be toggled off manually in
            Windows Security Center before this registry change takes effect)
          - Disables Windows Automatic Updates (service + Group Policy registry keys)
          - Disables Windows Firewall for all network profiles
          - Disables User Account Control (UAC) prompts
          - Disables automatic reboot on system failure

        After all steps complete a color-coded summary is printed.
        You are then prompted to launch install.ps1 directly if it exists on
        your Desktop or in the current directory.

        IMPORTANT: Run this script ONLY inside a dedicated virtual machine.
        It weakens the security posture of the system significantly.

    .PARAMETER noLaunch
        Skip the prompt to launch install.ps1 after preparation is complete.

    .EXAMPLE
        .\prepare-flarevm.ps1

        Description
        -----------
        Run all preparation steps and prompt to launch install.ps1.

    .EXAMPLE
        .\prepare-flarevm.ps1 -noLaunch

        Description
        -----------
        Run all preparation steps without prompting to launch install.ps1.

    .LINK
        https://github.com/mandiant/flare-vm
#>

[CmdletBinding()]
param(
    [switch]$noLaunch
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper: require Administrator
# ---------------------------------------------------------------------------
function Assert-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "[FAIL] This script must be run as Administrator. Exiting." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Helper: print a step result line
# ---------------------------------------------------------------------------
function Write-StepResult {
    param(
        [string]$label,
        [bool]$success,
        [string]$detail = ""
    )
    if ($success) {
        $msg = "  [ OK ] $label"
        if ($detail) { $msg += " — $detail" }
        Write-Host $msg -ForegroundColor Green
    } else {
        $msg = "  [WARN] $label"
        if ($detail) { $msg += " — $detail" }
        Write-Host $msg -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Helper: ensure a registry path exists, then set a value
# ---------------------------------------------------------------------------
function Set-RegistryValue {
    param(
        [string]$path,
        [string]$name,
        $value,
        [string]$type = "DWord"
    )
    try {
        if (-not (Test-Path $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        Set-ItemProperty -Path $path -Name $name -Value $value -Type $type -Force
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Step 1: Execution Policy
# ---------------------------------------------------------------------------
function Set-FlareExecutionPolicy {
    try {
        Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force -ErrorAction Stop
        Write-StepResult "Execution policy set to Unrestricted (LocalMachine)" $true
    } catch {
        # Fall back to CurrentUser scope if LocalMachine is locked by GPO
        try {
            Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force -ErrorAction Stop
            Write-StepResult "Execution policy set to Unrestricted (CurrentUser)" $true `
                "LocalMachine scope is locked by policy; CurrentUser scope used instead"
        } catch {
            Write-StepResult "Set execution policy" $false $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Step 2: Windows Defender — disable via Group Policy registry keys
# ---------------------------------------------------------------------------
function Disable-WindowsDefender {
    $defBase   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    $defRTP    = "$defBase\Real-Time Protection"
    $defSpyNet = "$defBase\Spynet"
    $defScan   = "$defBase\Scan"

    $ok = $true

    # Turn off the entire anti-spyware / anti-virus engine via policy
    $ok = $ok -and (Set-RegistryValue $defBase "DisableAntiSpyware" 1)
    $ok = $ok -and (Set-RegistryValue $defBase "DisableAntiVirus"   1)

    # Disable real-time protection components
    $ok = $ok -and (Set-RegistryValue $defRTP "DisableRealtimeMonitoring"        1)
    $ok = $ok -and (Set-RegistryValue $defRTP "DisableBehaviorMonitoring"         1)
    $ok = $ok -and (Set-RegistryValue $defRTP "DisableOnAccessProtection"         1)
    $ok = $ok -and (Set-RegistryValue $defRTP "DisableIOAVProtection"             1)
    $ok = $ok -and (Set-RegistryValue $defRTP "DisableScriptScanning"             1)
    $ok = $ok -and (Set-RegistryValue $defRTP "DisableIntrusionPreventionSystem"  1)

    # Disable cloud-delivered protection (MAPS) and sample submission
    $ok = $ok -and (Set-RegistryValue $defSpyNet "SpynetReporting"       0)
    $ok = $ok -and (Set-RegistryValue $defSpyNet "SubmitSamplesConsent"  2)

    # Disable scheduled scan
    $ok = $ok -and (Set-RegistryValue $defScan "DisableScanningNetworkFiles" 1)

    Write-StepResult "Windows Defender disabled via Group Policy registry" $ok

    # Disable Windows Defender scheduled tasks
    $tasks = @(
        "\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
        "\Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
        "\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
        "\Microsoft\Windows\Windows Defender\Windows Defender Verification"
    )
    $tasksOk = $true
    foreach ($task in $tasks) {
        try {
            $t = Get-ScheduledTask -TaskPath (Split-Path $task -Parent) `
                                   -TaskName  (Split-Path $task -Leaf) `
                                   -ErrorAction SilentlyContinue
            if ($null -ne $t) {
                Disable-ScheduledTask -TaskPath (Split-Path $task -Parent) `
                                      -TaskName  (Split-Path $task -Leaf) `
                                      -ErrorAction Stop | Out-Null
            }
        } catch {
            $tasksOk = $false
        }
    }
    Write-StepResult "Windows Defender scheduled tasks disabled" $tasksOk

    # Stop and disable the WinDefend service (best effort; protected on some builds)
    try {
        $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            Stop-Service  -Name WinDefend -Force -ErrorAction SilentlyContinue
            Set-Service   -Name WinDefend -StartupType Disabled -ErrorAction SilentlyContinue
            Write-StepResult "WinDefend service stopped and disabled" $true
        } else {
            Write-StepResult "WinDefend service" $true "service not found — skipped"
        }
    } catch {
        Write-StepResult "WinDefend service stop/disable" $false $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Step 3: Tamper Protection
# ---------------------------------------------------------------------------
function Disable-TamperProtection {
    # Value 4 = disabled, 5 = enabled.
    # This registry write only takes effect AFTER Tamper Protection has been
    # manually toggled off in the Windows Security Center UI (or via GPO).
    $path = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features"
    $ok   = Set-RegistryValue $path "TamperProtection" 4

    if ($ok) {
        Write-StepResult "Tamper Protection registry key set to disabled (4)" $true `
            "If Tamper Protection is still on, toggle it off in Windows Security Center first, then re-run this script"
    } else {
        Write-StepResult "Tamper Protection registry key" $false `
            "Could not write to $path — disable Tamper Protection manually in Windows Security Center"
    }
}

# ---------------------------------------------------------------------------
# Step 4: Windows Update
# ---------------------------------------------------------------------------
function Disable-WindowsUpdate {
    $auPath  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $wuPath  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

    $ok  = Set-RegistryValue $auPath "NoAutoUpdate"         1
    $ok  = $ok -and (Set-RegistryValue $auPath "AUOptions"  1)   # 1 = disable Automatic Updates entirely
    $ok  = $ok -and (Set-RegistryValue $wuPath "DisableWindowsUpdateAccess" 1)

    Write-StepResult "Windows Automatic Updates disabled via registry" $ok

    # Disable Update-related services
    $updateServices = @(
        @{ Name = "wuauserv";  Display = "Windows Update"                  },
        @{ Name = "UsoSvc";    Display = "Update Orchestrator Service"     },
        @{ Name = "WaaSMedicSvc"; Display = "Windows Update Medic Service" }
    )
    foreach ($svcInfo in $updateServices) {
        try {
            $svc = Get-Service -Name $svcInfo.Name -ErrorAction SilentlyContinue
            if ($null -ne $svc) {
                Stop-Service  -Name $svcInfo.Name -Force -ErrorAction SilentlyContinue
                # WaaSMedicSvc is a protected service; Set-Service may fail — that is expected
                Set-Service   -Name $svcInfo.Name -StartupType Disabled -ErrorAction SilentlyContinue
                Write-StepResult "$($svcInfo.Display) service stopped" $true
            }
        } catch {
            Write-StepResult "$($svcInfo.Display) service" $false $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5: Windows Firewall
# ---------------------------------------------------------------------------
function Disable-WindowsFirewall {
    try {
        Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction Stop
        Write-StepResult "Windows Firewall disabled (all profiles)" $true
    } catch {
        # Fallback to netsh for older builds
        $result = netsh advfirewall set allprofiles state off 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-StepResult "Windows Firewall disabled via netsh (all profiles)" $true
        } else {
            Write-StepResult "Windows Firewall disable" $false "$result"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 6: User Account Control (UAC)
# ---------------------------------------------------------------------------
function Disable-UAC {
    $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $ok   = Set-RegistryValue $path "EnableLUA"                     0
    $ok   = $ok -and (Set-RegistryValue $path "ConsentPromptBehaviorAdmin"  0)
    $ok   = $ok -and (Set-RegistryValue $path "PromptOnSecureDesktop"       0)

    Write-StepResult "User Account Control (UAC) disabled" $ok `
        "A reboot is required for UAC changes to take effect"
}

# ---------------------------------------------------------------------------
# Step 7: Automatic reboot on failure
# ---------------------------------------------------------------------------
function Disable-AutoRebootOnFailure {
    try {
        $computerSystem = Get-CimInstance -Class Win32_ComputerSystem -ErrorAction Stop
        $computerSystem | Invoke-CimMethod -MethodName SetAutomaticResetBootOption `
            -Arguments @{ Flag = $false } -ErrorAction Stop | Out-Null
        Write-StepResult "Automatic reboot on system failure disabled" $true
    } catch {
        # Fallback via registry
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
        $ok   = Set-RegistryValue $path "AutoReboot" 0
        Write-StepResult "Automatic reboot on system failure disabled via registry" $ok
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Assert-IsAdmin

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  FLARE-VM Pre-Installation Preparation" -ForegroundColor Cyan
Write-Host "  WARNING: Run ONLY inside a dedicated virtual machine!" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Set-FlareExecutionPolicy
Disable-TamperProtection
Disable-WindowsDefender
Disable-WindowsUpdate
Disable-WindowsFirewall
Disable-UAC
Disable-AutoRebootOnFailure

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Preparation complete." -ForegroundColor Green
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  1. If Tamper Protection was still enabled, toggle it OFF" -ForegroundColor White
Write-Host "     in Windows Security Center, then re-run this script." -ForegroundColor White
Write-Host "  2. Reboot the VM so all settings (UAC, Defender policy," -ForegroundColor White
Write-Host "     Windows Update) take full effect." -ForegroundColor White
Write-Host "  3. Run preflight.ps1 to confirm all checks pass." -ForegroundColor White
Write-Host "  4. Run install.ps1 to begin the FLARE-VM installation." -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($noLaunch) {
    exit 0
}

# Locate install.ps1
$installScript = $null
$candidates = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "install.ps1"),
    (Join-Path $PSScriptRoot "install.ps1"),
    (Join-Path (Get-Location) "install.ps1")
)
foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
        $installScript = $candidate
        break
    }
}

if ($null -ne $installScript) {
    Write-Host "install.ps1 found at: $installScript" -ForegroundColor Cyan
    $answer = Read-Host "Launch install.ps1 now? (Recommended: reboot first) [y/N]"
    if ($answer -match '^[Yy]') {
        Write-Host "Launching $installScript ..." -ForegroundColor Green
        & $installScript
    } else {
        Write-Host "Skipped. Remember to reboot before running install.ps1." -ForegroundColor Yellow
    }
} else {
    Write-Host "install.ps1 not found on Desktop or current directory." -ForegroundColor Yellow
    Write-Host "Download it with:" -ForegroundColor Yellow
    $downloadCmd = 'irm https://raw.githubusercontent.com/mandiant/flare-vm/main/install.ps1' +
                   " -OutFile `"$([Environment]::GetFolderPath('Desktop'))\install.ps1`""
    Write-Host "  $downloadCmd" -ForegroundColor White
}
