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
        Prepares a Windows 10+ virtual machine for FLARE VM installation.

    .DESCRIPTION
        Run this script as Administrator inside your VM before running install.ps1.
        It disables all settings that would block the FLARE VM installation:

          - Sets PowerShell execution policy to Unrestricted
          - Disables Tamper Protection via registry
          - Disables Windows Defender (real-time protection, Group Policy keys,
            scheduled tasks, stops and disables the WinDefend service)
          - Disables Windows Update (registry + stops/disables wuauserv, UsoSvc,
            WaaSMedicSvc)
          - Disables Windows Firewall for all network profiles
          - Disables User Account Control (UAC)
          - Disables automatic reboot on system failure

        After the script completes:
          1. Reboot the VM so that UAC, Defender policy, and Windows Update
             changes take full effect.
          2. Run preflight.ps1 to confirm all requirements pass.
          3. Run install.ps1 to start the FLARE VM installation.

        NOTE: Tamper Protection cannot be disabled purely via the registry while
        it is still enabled in the GUI. If it remains on after this script,
        toggle it off manually in:
          Windows Security -> Virus & threat protection settings -> Tamper Protection
        Then re-run this script.

    .EXAMPLE
        .\prepare-flarevm.ps1

        Description
        -----------
        Prepare the VM for FLARE VM installation.

    .LINK
        https://github.com/mandiant/flare-vm
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helper: write a status line with colour
# ---------------------------------------------------------------------------
function Write-Status {
    param(
        [string]$Message,
        [string]$Color = 'Cyan'
    )
    Write-Host "  $Message" -ForegroundColor $Color
}

function Write-OK    { param([string]$m) Write-Status "[ OK ] $m" 'Green'  }
function Write-Warn  { param([string]$m) Write-Status "[WARN] $m" 'Yellow' }
function Write-Fail  { param([string]$m) Write-Status "[FAIL] $m" 'Red'    }
function Write-Info  { param([string]$m) Write-Status "       $m" 'Gray'   }

# ---------------------------------------------------------------------------
# Helper: ensure a registry path exists and set a value
# ---------------------------------------------------------------------------
function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Helper: stop and disable a Windows service (best effort)
# ---------------------------------------------------------------------------
function Disable-WindowsService {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return }
    try {
        if ($svc.Status -eq 'Running') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction SilentlyContinue
    } catch {
        # best effort -- some protected services will resist
    }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  FLARE-VM Preparation Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Execution policy
# ---------------------------------------------------------------------------
Write-Host "[1/7] Setting execution policy to Unrestricted ..." -ForegroundColor Cyan
try {
    Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force -ErrorAction Stop
    Write-OK "Execution policy set to Unrestricted (LocalMachine)"
} catch {
    try {
        Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force -ErrorAction Stop
        Write-OK "Execution policy set to Unrestricted (CurrentUser)"
    } catch {
        Write-Fail "Could not set execution policy: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 2. Tamper Protection
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/7] Disabling Tamper Protection ..." -ForegroundColor Cyan

$tpPath = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features"
# Value 4 = disabled; value 5 = enabled
$ok = Set-RegistryValue -Path $tpPath -Name "TamperProtection" -Value 4 -Type DWord
if ($ok) {
    Write-OK "Tamper Protection registry key set to disabled (4)"
    Write-Warn "If Tamper Protection is still enabled in the GUI, disable it manually"
    Write-Info "Windows Security -> Virus & threat protection settings -> Tamper Protection"
    Write-Info "then re-run this script."
} else {
    Write-Fail "Could not set Tamper Protection registry key"
}

# ---------------------------------------------------------------------------
# 3. Windows Defender
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/7] Disabling Windows Defender ..." -ForegroundColor Cyan

# Group Policy registry keys (HKLM\SOFTWARE\Policies\Microsoft\Windows Defender)
$defPolicyPath    = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
$rtpPolicyPath    = "$defPolicyPath\Real-Time Protection"
$spynetPolicyPath = "$defPolicyPath\Spynet"

$defPolicySettings = @(
    @{ Path = $defPolicyPath;    Name = "DisableAntiSpyware";                 Value = 1 },
    @{ Path = $defPolicyPath;    Name = "DisableAntiVirus";                   Value = 1 }
)
$rtpPolicySettings = @(
    @{ Path = $rtpPolicyPath; Name = "DisableBehaviorMonitoring";        Value = 1 },
    @{ Path = $rtpPolicyPath; Name = "DisableOnAccessProtection";        Value = 1 },
    @{ Path = $rtpPolicyPath; Name = "DisableRealtimeMonitoring";        Value = 1 },
    @{ Path = $rtpPolicyPath; Name = "DisableScanOnRealtimeEnable";      Value = 1 },
    @{ Path = $rtpPolicyPath; Name = "DisableIOAVProtection";            Value = 1 }
)
$spynetPolicySettings = @(
    @{ Path = $spynetPolicyPath; Name = "DisableBlockAtFirstSeen";       Value = 1 },
    @{ Path = $spynetPolicyPath; Name = "SpynetReporting";               Value = 0 },
    @{ Path = $spynetPolicyPath; Name = "SubmitSamplesConsent";          Value = 2 }
)

$allDefenderSettings = $defPolicySettings + $rtpPolicySettings + $spynetPolicySettings
$defFailed = 0
foreach ($setting in $allDefenderSettings) {
    if (-not (Set-RegistryValue -Path $setting.Path -Name $setting.Name -Value $setting.Value)) {
        $defFailed++
    }
}

# Also set via the Defender feature key directly (belt-and-suspenders)
Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection" `
    -Name "DisableRealtimeMonitoring" -Value 1 | Out-Null
Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender" `
    -Name "DisableAntiSpyware" -Value 1 | Out-Null

if ($defFailed -eq 0) {
    Write-OK "Windows Defender Group Policy registry keys configured"
} else {
    Write-Warn "$defFailed Defender registry key(s) could not be set"
}

# Disable all Defender scheduled tasks
$defTasks = @(
    "\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
    "\Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
    "\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
    "\Microsoft\Windows\Windows Defender\Windows Defender Verification"
)
$taskFailed = 0
foreach ($task in $defTasks) {
    try {
        $taskPath = Split-Path $task
        $taskName = Split-Path $task -Leaf
        $t = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $t) {
            Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
                -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        $taskFailed++
    }
}
if ($taskFailed -eq 0) {
    Write-OK "Windows Defender scheduled tasks disabled"
} else {
    Write-Warn "$taskFailed Defender scheduled task(s) could not be disabled"
}

# Stop and disable WinDefend service
Disable-WindowsService -ServiceName "WinDefend"
Write-OK "WinDefend service stopped and disabled (best effort)"

# ---------------------------------------------------------------------------
# 4. Windows Update
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[4/7] Disabling Windows Update ..." -ForegroundColor Cyan

$wuPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$wuSettings = @(
    @{ Path = $wuPolicyPath; Name = "NoAutoUpdate";          Value = 1 },
    @{ Path = $wuPolicyPath; Name = "AUOptions";             Value = 1 },
    @{ Path = $wuPolicyPath; Name = "NoAutoRebootWithLoggedOnUsers"; Value = 1 }
)
$wuPath2 = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$wuSettings2 = @(
    @{ Path = $wuPath2; Name = "DisableWindowsUpdateAccess"; Value = 1 },
    @{ Path = $wuPath2; Name = "WUServer";                   Value = ""; Type = "String" },
    @{ Path = $wuPath2; Name = "WUStatusServer";             Value = ""; Type = "String" },
    @{ Path = $wuPath2; Name = "UpdateServiceUrlAlternate";  Value = ""; Type = "String" }
)

$wuFailed = 0
foreach ($setting in ($wuSettings + $wuSettings2)) {
    $type = if ($setting.ContainsKey('Type')) { $setting.Type } else { 'DWord' }
    if (-not (Set-RegistryValue -Path $setting.Path -Name $setting.Name `
                -Value $setting.Value -Type $type)) {
        $wuFailed++
    }
}

if ($wuFailed -eq 0) {
    Write-OK "Windows Update Group Policy registry keys configured"
} else {
    Write-Warn "$wuFailed Windows Update registry key(s) could not be set"
}

# Stop and disable update services
foreach ($svc in @("wuauserv", "UsoSvc", "WaaSMedicSvc")) {
    Disable-WindowsService -ServiceName $svc
}
Write-OK "Windows Update services stopped and disabled (best effort)"

# ---------------------------------------------------------------------------
# 5. Windows Firewall
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[5/7] Disabling Windows Firewall ..." -ForegroundColor Cyan
try {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction Stop
    Write-OK "Windows Firewall disabled for all profiles (Domain, Public, Private)"
} catch {
    # Fallback to netsh if Set-NetFirewallProfile is unavailable
    try {
        netsh advfirewall set allprofiles state off 2>&1 | Out-Null
        Write-OK "Windows Firewall disabled via netsh"
    } catch {
        Write-Fail "Could not disable Windows Firewall: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 6. User Account Control (UAC)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[6/7] Disabling User Account Control (UAC) ..." -ForegroundColor Cyan

$uacPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$uacSettings = @(
    @{ Name = "EnableLUA";                  Value = 0 },
    @{ Name = "ConsentPromptBehaviorAdmin"; Value = 0 },
    @{ Name = "PromptOnSecureDesktop";      Value = 0 }
)
$uacFailed = 0
foreach ($setting in $uacSettings) {
    if (-not (Set-RegistryValue -Path $uacPath -Name $setting.Name -Value $setting.Value)) {
        $uacFailed++
    }
}
if ($uacFailed -eq 0) {
    Write-OK "UAC disabled (takes effect after reboot)"
} else {
    Write-Warn "$uacFailed UAC registry key(s) could not be set"
}

# ---------------------------------------------------------------------------
# 7. Disable automatic reboot on system failure
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[7/7] Disabling automatic reboot on system failure ..." -ForegroundColor Cyan

$crashPath = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
$ok = Set-RegistryValue -Path $crashPath -Name "AutoReboot" -Value 0
if ($ok) {
    Write-OK "Automatic reboot on system failure disabled"
} else {
    Write-Fail "Could not disable automatic reboot on system failure"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Preparation complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Reboot this VM to apply UAC, Defender policy, and Windows Update changes."
Write-Host "  2. Run .\preflight.ps1 to confirm all requirements pass."
Write-Host "  3. Run .\install.ps1 to start the FLARE VM installation."
Write-Host ""
Write-Host "NOTE: If Tamper Protection is still enabled after the reboot, disable it" -ForegroundColor Yellow
Write-Host "      manually via Windows Security -> Virus & threat protection settings" -ForegroundColor Yellow
Write-Host "      -> Tamper Protection, then re-run this script." -ForegroundColor Yellow
Write-Host ""
