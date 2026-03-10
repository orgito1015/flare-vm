# ============================================================
#  FlareVM Pre-Installation Prep Script
#  Run BEFORE executing FlareVM's install.ps1
#  Run as Administrator in PowerShell
#  Tested on: Windows 10 (clean snapshot recommended first)
# ============================================================

#Requires -RunAsAdministrator
$ErrorActionPreference = "SilentlyContinue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  FlareVM Pre-Install Prep Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ─────────────────────────────────────────────
# STEP 1 — Set PowerShell Execution Policy
# (Most common reason FlareVM install.ps1 fails)
# ─────────────────────────────────────────────
Write-Host "[1] Setting PowerShell Execution Policy to Unrestricted..." -ForegroundColor Green
Set-ExecutionPolicy Unrestricted -Scope LocalMachine -Force
Set-ExecutionPolicy Unrestricted -Scope CurrentUser -Force
Set-ExecutionPolicy Bypass -Scope Process -Force

# Also set via registry to survive policy resets
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" `
    -Name "ExecutionPolicy" -Value "Unrestricted" -Force
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" `
    -Name "ExecutionPolicy" -Value "Unrestricted" -Force

Write-Host "    Done. Execution policy: $(Get-ExecutionPolicy -Scope LocalMachine)" -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 2 — Disable Windows Defender (Real-Time)
# Defender blocks Chocolatey downloads and tool installs
# ─────────────────────────────────────────────
Write-Host "`n[2] Disabling Windows Defender..." -ForegroundColor Green

# Disable via PowerShell cmdlet
Set-MpPreference -DisableRealtimeMonitoring $true
Set-MpPreference -DisableBehaviorMonitoring $true
Set-MpPreference -DisableBlockAtFirstSeen $true
Set-MpPreference -DisableIOAVProtection $true
Set-MpPreference -DisableScriptScanning $true
Set-MpPreference -MAPSReporting Disabled
Set-MpPreference -SubmitSamplesConsent NeverSend
Set-MpPreference -DisableIntrusionPreventionSystem $true

# Disable via registry (survives reboots)
$defKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
New-Item -Path $defKey -Force | Out-Null
Set-ItemProperty -Path $defKey -Name "DisableAntiSpyware" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $defKey -Name "DisableAntiVirus"   -Value 1 -Type DWord -Force

$rtpKey = "$defKey\Real-Time Protection"
New-Item -Path $rtpKey -Force | Out-Null
Set-ItemProperty -Path $rtpKey -Name "DisableRealtimeMonitoring"     -Value 1 -Type DWord -Force
Set-ItemProperty -Path $rtpKey -Name "DisableBehaviorMonitoring"      -Value 1 -Type DWord -Force
Set-ItemProperty -Path $rtpKey -Name "DisableOnAccessProtection"      -Value 1 -Type DWord -Force
Set-ItemProperty -Path $rtpKey -Name "DisableScanOnRealtimeEnable"    -Value 1 -Type DWord -Force
Set-ItemProperty -Path $rtpKey -Name "DisableIOAVProtection"          -Value 1 -Type DWord -Force

# Stop and disable Defender services
foreach ($svc in @("WinDefend","WdNisSvc","SecurityHealthService","wscsvc")) {
    Stop-Service $svc -Force
    Set-Service  $svc -StartupType Disabled
}

# Disable Windows Defender scheduled scans
foreach ($task in @(
    "\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
    "\Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
    "\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
    "\Microsoft\Windows\Windows Defender\Windows Defender Verification"
)) {
    $path = Split-Path $task; $name = Split-Path $task -Leaf
    Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "    Defender real-time protection disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 3 — Disable Windows Update
# Prevents mid-install reboots or service interference
# ─────────────────────────────────────────────
Write-Host "`n[3] Disabling Windows Update..." -ForegroundColor Green

foreach ($svc in @("wuauserv","UsoSvc","WaaSMedicSvc","BITS","DoSvc")) {
    Stop-Service $svc -Force
    Set-Service  $svc -StartupType Disabled
}

$wuKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-Item -Path $wuKey -Force | Out-Null
Set-ItemProperty -Path $wuKey -Name "NoAutoUpdate"                  -Value 1 -Type DWord -Force
Set-ItemProperty -Path $wuKey -Name "AUOptions"                     -Value 1 -Type DWord -Force
Set-ItemProperty -Path $wuKey -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord -Force

Disable-ScheduledTask -TaskPath "\Microsoft\Windows\UpdateOrchestrator\" -TaskName "Schedule Scan"   -ErrorAction SilentlyContinue | Out-Null
Disable-ScheduledTask -TaskPath "\Microsoft\Windows\WindowsUpdate\"      -TaskName "Scheduled Start" -ErrorAction SilentlyContinue | Out-Null

Write-Host "    Windows Update disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 4 — Disable UAC
# UAC prompts break unattended Chocolatey installs
# ─────────────────────────────────────────────
Write-Host "`n[4] Disabling UAC..." -ForegroundColor Green

$uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $uacKey -Name "EnableLUA"                     -Value 0 -Type DWord -Force
Set-ItemProperty -Path $uacKey -Name "ConsentPromptBehaviorAdmin"     -Value 0 -Type DWord -Force
Set-ItemProperty -Path $uacKey -Name "ConsentPromptBehaviorUser"      -Value 0 -Type DWord -Force
Set-ItemProperty -Path $uacKey -Name "PromptOnSecureDesktop"          -Value 0 -Type DWord -Force

Write-Host "    UAC disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 5 — Disable SmartScreen
# SmartScreen blocks downloaded tools and installers
# ─────────────────────────────────────────────
Write-Host "`n[5] Disabling SmartScreen..." -ForegroundColor Green

Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" `
    -Name "EnableSmartScreen" -Value 0 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" `
    -Name "SmartScreenEnabled" -Value "Off" -Force
Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" `
    -Name "EnableWebContentEvaluation" -Value 0 -Type DWord -Force

# Disable SmartScreen for Microsoft Edge (Chromium)
$edgeKey = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
New-Item -Path $edgeKey -Force | Out-Null
Set-ItemProperty -Path $edgeKey -Name "SmartScreenEnabled"               -Value 0 -Type DWord -Force
Set-ItemProperty -Path $edgeKey -Name "PreventSmartScreenPromptOverride" -Value 0 -Type DWord -Force

Write-Host "    SmartScreen disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 6 — Unblock Downloads (Zone Identifier)
# Windows marks downloaded files as "untrusted" (Zone 3)
# This causes silent failures when running installers
# ─────────────────────────────────────────────
Write-Host "`n[6] Disabling zone/attachment blocking for downloads..." -ForegroundColor Green

# Disable "Open File - Security Warning" for all zones
$zoneKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Zones\3"
New-Item -Path $zoneKey -Force | Out-Null
Set-ItemProperty -Path $zoneKey -Name "1806" -Value 0 -Type DWord -Force  # Launching apps and unsafe files

# Disable "Always ask before opening" for attachments
$attachKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments"
New-Item -Path $attachKey -Force | Out-Null
Set-ItemProperty -Path $attachKey -Name "SaveZoneInformation"    -Value 1 -Type DWord -Force
Set-ItemProperty -Path $attachKey -Name "ScanWithAntiVirus"      -Value 1 -Type DWord -Force
Set-ItemProperty -Path $attachKey -Name "HideZoneInfoOnProperties" -Value 1 -Type DWord -Force

$attachKey2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments"
New-Item -Path $attachKey2 -Force | Out-Null
Set-ItemProperty -Path $attachKey2 -Name "SaveZoneInformation"   -Value 1 -Type DWord -Force

Write-Host "    Download zone blocking disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 7 — Disable Windows Firewall
# Can block Chocolatey, pip, gem, and other package managers
# ─────────────────────────────────────────────
Write-Host "`n[7] Disabling Windows Firewall..." -ForegroundColor Green

Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
netsh advfirewall set allprofiles state off | Out-Null

Write-Host "    Firewall disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 8 — Install / Update Chocolatey
# FlareVM uses Chocolatey as its package manager
# ─────────────────────────────────────────────
Write-Host "`n[8] Ensuring Chocolatey is installed and up to date..." -ForegroundColor Green

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "    Installing Chocolatey..." -ForegroundColor DarkGray
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
} else {
    Write-Host "    Chocolatey already installed. Upgrading..." -ForegroundColor DarkGray
    choco upgrade chocolatey -y --no-progress
}

# Chocolatey settings for unattended FlareVM install
choco feature enable  -n allowGlobalConfirmation     --no-progress
choco feature disable -n showDownloadProgress        --no-progress
choco feature enable  -n useRememberedArgumentsForUpgrades --no-progress

Write-Host "    Chocolatey ready." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 9 — Ensure .NET 3.5 & .NET 4.8 are present
# Many FlareVM tools require these
# ─────────────────────────────────────────────
Write-Host "`n[9] Enabling .NET Framework 3.5..." -ForegroundColor Green

$net35 = Get-WindowsOptionalFeature -Online -FeatureName NetFx3 -ErrorAction SilentlyContinue
if ($net35.State -ne "Enabled") {
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart | Out-Null
    Write-Host "    .NET 3.5 enabled." -ForegroundColor DarkGray
} else {
    Write-Host "    .NET 3.5 already enabled." -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────
# STEP 10 — Set Correct TLS Version for Downloads
# Without this, Invoke-WebRequest and WebClient fail
# on modern HTTPS endpoints (Chocolatey, GitHub, etc.)
# ─────────────────────────────────────────────
Write-Host "`n[10] Forcing TLS 1.2 for web requests..." -ForegroundColor Green

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor `
                                                      [System.Net.SecurityProtocolType]::Tls11 -bor `
                                                      [System.Net.SecurityProtocolType]::Tls

# Persist TLS 1.2 in registry
$netKey = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
New-Item -Path $netKey -Force | Out-Null
Set-ItemProperty -Path $netKey -Name "SchUseStrongCrypto" -Value 1 -Type DWord -Force

$netKey2 = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
New-Item -Path $netKey2 -Force | Out-Null
Set-ItemProperty -Path $netKey2 -Name "SchUseStrongCrypto" -Value 1 -Type DWord -Force

Write-Host "    TLS 1.2 enforced." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 11 — Disable Controlled Folder Access
# Blocks writes to Desktop/Documents — breaks installs
# ─────────────────────────────────────────────
Write-Host "`n[11] Disabling Controlled Folder Access..." -ForegroundColor Green

Set-MpPreference -EnableControlledFolderAccess Disabled

Write-Host "    Controlled Folder Access disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 12 — Add Exclusions to Defender for FlareVM Paths
# Belt-and-suspenders: even if Defender is "off",
# exclusions prevent it from interfering if it restarts
# ─────────────────────────────────────────────
Write-Host "`n[12] Adding Defender exclusions for FlareVM paths..." -ForegroundColor Green

$excludePaths = @(
    "C:\",
    "C:\Users\$env:USERNAME\Desktop",
    "C:\Tools",
    "C:\ProgramData\chocolatey",
    "$env:TEMP",
    "$env:SystemRoot\Temp",
    "C:\Users\$env:USERNAME\AppData"
)
foreach ($path in $excludePaths) {
    Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
}

# Exclude common malware analysis processes
$excludeProcs = @(
    "python.exe","python3.exe","pythonw.exe",
    "powershell.exe","pwsh.exe","cmd.exe",
    "choco.exe","chocolatey.exe",
    "curl.exe","wget.exe",
    "git.exe","msbuild.exe",
    "x64dbg.exe","x32dbg.exe","ollydbg.exe","windbg.exe",
    "wireshark.exe","procmon.exe","procexp.exe","autoruns.exe"
)
foreach ($proc in $excludeProcs) {
    Add-MpPreference -ExclusionProcess $proc -ErrorAction SilentlyContinue
}

Write-Host "    Exclusions added." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 13 — Disable Windows Error Recovery on Boot
# Prevents "Windows failed to start" loop after
# Defender or other services are forcibly stopped
# ─────────────────────────────────────────────
Write-Host "`n[13] Disabling Windows boot recovery prompts..." -ForegroundColor Green

bcdedit /set recoveryenabled No           | Out-Null
bcdedit /set bootstatuspolicy IgnoreAllFailures | Out-Null

Write-Host "    Boot recovery disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 14 — Disable Automatic Restart on BSOD
# ─────────────────────────────────────────────
Write-Host "`n[14] Disabling auto-reboot on BSOD..." -ForegroundColor Green

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" `
    -Name "AutoReboot" -Value 0 -Type DWord -Force

Write-Host "    Auto-reboot on BSOD disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 15 — Extend PowerShell Timeout / Memory
# Long installs can hit default limits
# ─────────────────────────────────────────────
Write-Host "`n[15] Tuning PowerShell and system limits..." -ForegroundColor Green

# Increase maximum download limit for WebClient
[System.Net.ServicePointManager]::DefaultConnectionLimit = 512

# Disable progress bar (speeds up Invoke-WebRequest significantly)
$ProgressPreference = 'SilentlyContinue'

# Persist in profile
$profileContent = @"
`$ProgressPreference = 'SilentlyContinue'
`$ErrorActionPreference = 'SilentlyContinue'
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
Set-ExecutionPolicy Bypass -Scope Process -Force
"@
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
Add-Content -Path $PROFILE -Value $profileContent

Write-Host "    PowerShell profile tuned." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 16 — Disable Hibernate & Sleep
# Prevents VM from sleeping during long installs
# ─────────────────────────────────────────────
Write-Host "`n[16] Disabling sleep and hibernate..." -ForegroundColor Green

powercfg /hibernate off                  | Out-Null
powercfg /change standby-timeout-ac   0  | Out-Null
powercfg /change hibernate-timeout-ac 0  | Out-Null
powercfg /change monitor-timeout-ac   0  | Out-Null
powercfg /setactive SCHEME_MIN            | Out-Null

Write-Host "    Sleep/hibernate disabled." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 17 — Disable Proxy / IE Settings that break downloads
# ─────────────────────────────────────────────
Write-Host "`n[17] Clearing proxy settings..." -ForegroundColor Green

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
    -Name "ProxyEnable" -Value 0 -Type DWord -Force
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" `
    -Name "ProxyServer" -ErrorAction SilentlyContinue

netsh winhttp reset proxy | Out-Null

Write-Host "    Proxy cleared." -ForegroundColor DarkGray

# ─────────────────────────────────────────────
# STEP 18 — Verify Internet Connectivity
# ─────────────────────────────────────────────
Write-Host "`n[18] Checking internet connectivity..." -ForegroundColor Green

$testHosts = @("community.chocolatey.org","raw.githubusercontent.com","github.com")
foreach ($h in $testHosts) {
    $result = Test-NetConnection -ComputerName $h -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($result) {
        Write-Host "    [OK] $h" -ForegroundColor DarkGray
    } else {
        Write-Host "    [WARN] Cannot reach $h - check network!" -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────
# DONE — Print next steps
# ─────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  PREP COMPLETE — System is FlareVM ready" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Download FlareVM installer:" -ForegroundColor White
Write-Host "     https://github.com/mandiant/flare-vm" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  2. Run FlareVM install (from an admin PowerShell):" -ForegroundColor White
Write-Host "     (New-Object net.webclient).DownloadFile('https://raw.githubusercontent.com/mandiant/flare-vm/main/install.ps1','" '$env:temp\install.ps1')" -ForegroundColor DarkCyan
Write-Host "     Unblock-File -Path `"`$env:temp\install.ps1`"" -ForegroundColor DarkCyan
Write-Host "     Set-ExecutionPolicy Unrestricted -Force" -ForegroundColor DarkCyan
Write-Host "     `"`$env:temp\install.ps1`"" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  3. Take a VM snapshot NOW before running install!" -ForegroundColor Red
Write-Host ""
