<#
.SYNOPSIS
    A professional-grade PowerShell script to optimize Windows 10/11 for gaming performance and low latency.

.DESCRIPTION
    This script provides a user-friendly, logically grouped menu to apply a wide range of system tweaks.
    It is built for maximum safety with proactive system checks, idempotent functions, a robust backup/restore mechanism,
    and command-line parameters for automation.

.NOTES
    Author: XeinTDM
#>

#region Preamble and Initial Checks

#requires -Version 5.1
#requires -RunAsAdministrator

param (
    [switch]$ApplyAll,
    [switch]$Restore,
    [switch]$CreateRestorePoint
)

# Prevents multiple backup files from being created in a single session.
$global:backupCreated = $false
$BackupFile = Join-Path $env:TEMP "WindowsGamingOptimization_Backup.json"

# Handle pre-existing backup files for safety
if ((-not $Restore) -and (Test-Path $BackupFile)) {
    Write-Host "An existing backup file was found: $BackupFile" -ForegroundColor Yellow
    Write-Host "This file might be from a previous, unfinished session." -ForegroundColor Yellow
    $choice = Read-Host "Do you want to [O]verwrite it with a new backup, [U]se the existing one, or [A]bort? (O/U/A)"
    switch ($choice.ToUpper()) {
        'O' { Remove-Item $BackupFile -Force; Write-Host "Existing backup file removed. A new one will be created." -ForegroundColor Green }
        'U' { $global:backupCreated = $true; Write-Host "Using existing backup file for this session. No new backup will be made." -ForegroundColor Cyan }
        default { Write-Host "Operation aborted by user." -ForegroundColor Red; exit }
    }
}

#endregion

#region Central Configuration

$config = @{
    PowerPlan = @{
        UltimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
        HighPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
        BalancedGuid = "381b4222-f694-41f0-9685-ff5bb260df2e"
    };
    ServicesToDisable = "SysMain", "Spooler", # Caution: Disabling Spooler prevents printing.
                        "MapsBroker", "diagtrack", "dmwappushservice";
    Registry = @{
        # TweakName = @{ Path, Name, Value(Optimized), Type, Category, Description, Default(Optional) }
        GameMode = @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AllowAutoGameMode"; Value = 1; Type = "DWord"; Category = "Global"; Description = "Enable Game Mode" }
        GameBar  = @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled"; Value = 0; Type = "DWord"; Category = "Global"; Description = "Disable Game Bar" }
        GameDVR  = @{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0; Type = "DWord"; Category = "Global"; Description = "Disable Game DVR" }
        VisualFX = @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; Name = "VisualFxSetting"; Value = 2; Type = "DWord"; Category = "Global"; Description = "Set Visual Effects to Best Performance" } # 2 = Best Performance
        HAGS     = @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "HwSchMode"; Value = 2; Type = "DWord"; Category = "Global"; Description = "Enable Hardware-accelerated GPU Scheduling" } # 2 = Enabled
        NetThrottling = @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; Name = "NetworkThrottlingIndex"; Value = [uint32]0xFFFFFFFF; Type = "DWord"; Category = "Global"; Description = "Disable Network Throttling" }

        MouseSpeed      = @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSpeed"; Value = "0"; Type = "String"; Category = "Mouse"; Description = "Disable Mouse Acceleration (Speed)"; Default = "1" }
        MouseThreshold1 = @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String"; Category = "Mouse"; Description = "Disable Mouse Acceleration (Threshold 1)"; Default = "6" }
        MouseThreshold2 = @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String"; Category = "Mouse"; Description = "Disable Mouse Acceleration (Threshold 2)"; Default = "10" }
    }
}

#endregion

#region Core Functions

Function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "ACTION", "SUCCESS", "WARN", "ERROR")][string]$Level, [int]$Indent = 0)
    $colorMap = @{ INFO="Cyan"; ACTION="Yellow"; SUCCESS="Green"; WARN="DarkYellow"; ERROR="Red" }
    Write-Host (" " * ($Indent * 2) + $Message) -ForegroundColor $colorMap[$Level]
}

Function Create-SystemRestorePoint {
    Write-Log -Level ACTION -Message "Checking System Restore status..."
    $systemDrive = $env:SystemDrive
    try {
        if ((Get-CimInstance -Namespace "root\default" -ClassName "SystemRestore" -ErrorAction Stop).GetProtectionStatus($systemDrive).ProtectionStatus -ne 1) {
            Write-Log -Level WARN -Message "System Restore is not enabled on your system drive ($systemDrive)."
            Write-Log -Level WARN -Message "It is highly recommended to enable it for safety: System Properties -> System Protection."
            if ($PSBoundParameters.Keys.Count -gt 0) { return } # Don't prompt in non-interactive mode
            if ((Read-Host "Continue without creating a restore point? (Y/N)").ToLower() -ne 'y') { return }
        }
    }
    catch {
        Write-Log -Level WARN -Message "Could not query System Restore status. It may be disabled system-wide. $($_.Exception.Message)"
        return
    }

    Write-Log -Level ACTION -Message "Creating System Restore Point. This may take a few minutes..."
    try {
        $rp = Checkpoint-Computer -Description "Before Gaming Optimization" -ErrorAction Stop
        Write-Log -Level SUCCESS -Message "Successfully created System Restore Point: $($rp.Description)"
    }
    catch {
        Write-Log -Level ERROR -Message "Failed to create Restore Point. Error: $($_.Exception.Message)"
    }
}

Function Invoke-Backup {
    if ($global:backupCreated) { return }
    Write-Log -Level ACTION -Message "Backing up original settings to '$BackupFile'..."
    $backupData = @{ PowerPlan = $null; Services = @{}; Registry = @{} }

    # Backup Active Power Plan
    try {
        $activeSchemeOutput = powercfg /getactivescheme -ErrorAction Stop
        if ($activeSchemeOutput -match '([a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12})') { $backupData.PowerPlan = $matches[1] }
    } catch {
        Write-Log -Level WARN -Message "Could not get active power scheme. Backup for power plan may be incomplete."
    }

    # Backup Services
    $config.ServicesToDisable | ForEach-Object {
        $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($svc) { $backupData.Services[$_] = $svc.StartType }
    }

    # Backup Registry Keys (Global and Mouse)
    $registryTweaksToBackup = $config.Registry.GetEnumerator() | Where-Object { $_.Value.Category -in ('Global', 'Mouse') }
    foreach ($tweak in $registryTweaksToBackup) {
        $keyInfo = $tweak.Value
        $regValue = Get-ItemProperty -Path $keyInfo.Path -Name $keyInfo.Name -ErrorAction SilentlyContinue
        if ($null -ne $regValue) { $backupData.Registry["$($keyInfo.Path)\$($keyInfo.Name)"] = $regValue.($keyInfo.Name) }
    }

    $backupData | ConvertTo-Json -Depth 5 | Out-File -FilePath $BackupFile -Encoding UTF8
    $global:backupCreated = $true
    Write-Log -Level SUCCESS -Message "Backup completed successfully."
}

Function Restore-BackedUpSettings {
    if (-not (Test-Path $BackupFile)) { Write-Log -Level ERROR -Message "No backup file found at '$BackupFile'."; return }
    Write-Log -Level ACTION -Message "Restoring settings from backup..."
    $backupData = Get-Content -Path $BackupFile | ConvertFrom-Json

    # Restore Power Plan
    Write-Log -Level INFO -Message "Restoring Power Plan..." -Indent 1
    if ($null -ne $backupData.PowerPlan) {
        try { powercfg /setactive $backupData.PowerPlan -ErrorAction Stop | Out-Null; Write-Log -Level SUCCESS -Message "Active Power Plan restored." -Indent 2 }
        catch { Write-Log -Level ERROR -Message "Failed to restore Power Plan. Error: $($_.Exception.Message)" -Indent 2 }
    } else { Write-Log -Level WARN -Message "No Power Plan data in backup. Skipping." -Indent 2 }

    # Restore Services
    Write-Log -Level INFO -Message "Restoring Services..." -Indent 1
    foreach ($e in $backupData.Services.PSObject.Properties) {
        try { Set-Service -Name $e.Name -StartupType $e.Value -ErrorAction Stop; Write-Log -Level SUCCESS -Message "Service '$($e.Name)' startup type restored to '$($e.Value)'." -Indent 2 }
        catch { Write-Log -Level ERROR -Message "Failed to restore service '$($e.Name)'. Error: $($_.Exception.Message)" -Indent 2 }
    }

    # Restore Registry
    Write-Log -Level INFO -Message "Restoring Registry Keys..." -Indent 1
    foreach ($e in $backupData.Registry.PSObject.Properties) {
        if ($null -eq $e.Value) { continue }
        $fullKeyPath = $e.Name
        $parentPath = $fullKeyPath.Substring(0, $fullKeyPath.LastIndexOf('\'))
        $leafName = $fullKeyPath.Substring($fullKeyPath.LastIndexOf('\') + 1)
        try {
            if (-not (Test-Path $parentPath)) { Write-Log -Level WARN -Message "Registry path '$parentPath' not found. Skipping restore for '$leafName'." -Indent 2; continue }
            Set-ItemProperty -Path $parentPath -Name $leafName -Value $e.Value -ErrorAction Stop
            Write-Log -Level SUCCESS -Message "Registry key '$leafName' restored." -Indent 2
        } catch { Write-Log -Level ERROR -Message "Failed to restore registry key '$leafName'. Error: $($_.Exception.Message)" -Indent 2 }
    }

    Write-Log -Level SUCCESS -Message "Settings restoration complete. A restart is recommended."
    Remove-Item -Path $BackupFile -Force; Write-Log -Level INFO -Message "Backup file has been removed."
}

#endregion

#region Optimization Functions

Function Apply-RegistryTweaks {
    param ([string[]]$Categories, [switch]$Silent)
    if (-not $Silent) { Invoke-Backup }
    
    $tweaksToApply = $config.Registry.GetEnumerator() | Where-Object { $Categories -contains $_.Value.Category }
    foreach ($tweak in $tweaksToApply) {
        $keyInfo = $tweak.Value
        if (-not (Test-Path $keyInfo.Path)) { 
            try { New-Item -Path $keyInfo.Path -Force -ErrorAction Stop | Out-Null }
            catch { Write-Log -Level ERROR -Message "Could not create registry path '$($keyInfo.Path)'. Skipping tweak '$($tweak.Name)'." -Indent 1; continue }
        }
        
        $currentValue = (Get-ItemProperty -Path $keyInfo.Path -Name $keyInfo.Name -ErrorAction SilentlyContinue).($keyInfo.Name)
        if ($null -eq $currentValue -or $currentValue -ne $keyInfo.Value) {
            try {
                Set-ItemProperty -Path $keyInfo.Path -Name $keyInfo.Name -Value $keyInfo.Value -Type $keyInfo.Type -Force -ErrorAction Stop
                Write-Log -Level SUCCESS -Message "$($keyInfo.Description) - Applied." -Indent 1
            } catch {
                Write-Log -Level ERROR -Message "Failed to apply tweak '$($tweak.Name)'. Error: $($_.Exception.Message)" -Indent 1
            }
        } else {
            Write-Log -Level INFO -Message "$($keyInfo.Description) - Already optimized." -Indent 1
        }
    }
}

Function Invoke-AllOptimizations {
    Write-Log -Level ACTION -Message "Applying all safe, global optimizations..."
    Invoke-Backup
    Set-UltimatePerformancePlan -Silent
    Disable-UnnecessaryServices -Silent
    Write-Log -Level ACTION -Message "Applying registry optimizations..." -Indent 0
    Apply-RegistryTweaks -Categories "Global", "Mouse" -Silent
    ipconfig /flushdns | Out-Null; Write-Log -Level SUCCESS -Message "DNS cache cleared." -Indent 1
    Write-Log -Level SUCCESS -Message "`nAll global optimizations applied!"
}

Function Set-UltimatePerformancePlan { param([switch]$Silent)
    if (-not $Silent) { Invoke-Backup; Write-Log -Level ACTION -Message "Optimizing Power Plan..." }
    $guid = $config.PowerPlan.UltimateGuid
    if ((powercfg /l | Select-String -Pattern $guid -SimpleMatch -Quiet)) {
        if ((powercfg /getactivescheme) -match $guid) { Write-Log -Level INFO -Message "Ultimate Performance plan already active." -Indent 1; return }
    } else {
        powercfg -duplicatescheme $config.PowerPlan.HighPerfGuid $guid | Out-Null
        Write-Log -Level INFO -Message "Created Ultimate Performance plan." -Indent 1
    }
    powercfg /setactive $guid | Out-Null; Write-Log -Level SUCCESS -Message "Ultimate Performance power plan activated." -Indent 1
}

Function Disable-UnnecessaryServices { param([switch]$Silent)
    if (-not $Silent) { Invoke-Backup; Write-Log -Level ACTION -Message "Disabling unnecessary background services..." }
    $servicesToConfirm = @{ "Spooler" = "This will disable printing capabilities." }

    foreach ($serviceName in $config.ServicesToDisable) {
        if (-not $Silent -and $servicesToConfirm.ContainsKey($serviceName)) {
            $prompt = "WARNING: Disabling '$serviceName' has consequences. $($servicesToConfirm[$serviceName])`nAre you sure you want to disable it? (Y/N)"
            if ((Read-Host $prompt).ToLower() -ne 'y') { Write-Log -Level WARN -Message "Skipping '$serviceName'." -Indent 1; continue }
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.StartType -ne "Disabled") {
            try {
                if ($service.Status -eq 'Running') { Stop-Service -Name $serviceName -Force -ErrorAction Stop }
                Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
                Write-Log -Level SUCCESS -Message "Service '$serviceName' disabled." -Indent 1
            } catch {
                Write-Log -Level ERROR -Message "Failed to disable service '$serviceName'. Error: $($_.Exception.Message)" -Indent 1
            }
        }
    }
}

Function Enable-HAGS {
    if ((Get-CimInstance Win32_OperatingSystem).BuildNumber -lt 19041) {
        Write-Log -Level ERROR -Message "HAGS requires Windows 10 (2004) or newer. Operation aborted."
        return
    }
    Write-Log -Level ACTION -Message "Applying Hardware-accelerated GPU Scheduling (HAGS) Tweak..."
    Invoke-Backup
    
    $keyInfo = $config.Registry.HAGS
    $currentValue = (Get-ItemProperty -Path $keyInfo.Path -Name $keyInfo.Name -ErrorAction SilentlyContinue).($keyInfo.Name)

    if ($null -eq $currentValue -or $currentValue -ne $keyInfo.Value) {
        try {
            if (-not (Test-Path $keyInfo.Path)) { New-Item -Path $keyInfo.Path -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $keyInfo.Path -Name $keyInfo.Name -Value $keyInfo.Value -Type $keyInfo.Type -Force -ErrorAction Stop
            Write-Log -Level SUCCESS -Message "$($keyInfo.Description) - Applied. A RESTART is REQUIRED." -Indent 1
        } catch {
            Write-Log -Level ERROR -Message "Failed to apply HAGS tweak. Error: $($_.Exception.Message)" -Indent 1
        }
    } else {
        Write-Log -Level INFO -Message "$($keyInfo.Description) - Already optimized." -Indent 1
    }
}

Function Select-ExeAndApplyTweak {
    param([string]$WindowTitle, [string]$RegistryPath, [string]$Value, [string]$SuccessMessage)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $fd = New-Object System.Windows.Forms.OpenFileDialog; $fd.Title = $WindowTitle; $fd.Filter = "Executables (*.exe)|*.exe"
        if ($fd.ShowDialog() -eq "OK") {
            $exePath = $fd.FileName
            if (-not (Test-Path $RegistryPath)) { New-Item -Path $RegistryPath -Force | Out-Null }
            Set-ItemProperty -Path $RegistryPath -Name $exePath -Value $Value
            Write-Log -Level SUCCESS -Message ($SuccessMessage -f [System.IO.Path]::GetFileName($exePath))
        } else { Write-Log -Level INFO -Message "Operation cancelled by user." }
    }
    catch { Write-Log -Level ERROR -Message "Could not apply tweak. Error: $($_.Exception.Message)" }
}

#endregion

#region Restoration / Reversal Functions

Function Revert-RegistryTweaksToDefault {
    param ([string[]]$Categories)
    Write-Log -Level ACTION -Message "Reverting registry settings in categories: $($Categories -join ', ')"
    $tweaksToRevert = $config.Registry.GetEnumerator() | Where-Object { $Categories -contains $_.Value.Category -and $_.Value.PSObject.Properties.Name -contains 'Default' }
    foreach ($tweak in $tweaksToRevert) {
        $keyInfo = $tweak.Value
        try {
            Set-ItemProperty -Path $keyInfo.Path -Name $keyInfo.Name -Value $keyInfo.Default -Type $keyInfo.Type -Force -ErrorAction Stop
            Write-Log -Level SUCCESS -Message "$($keyInfo.Description) - Reverted to default." -Indent 1
        } catch { Write-Log -Level ERROR -Message "Failed to revert '$($tweak.Name)'. Error: $($_.Exception.Message)" -Indent 1 }
    }
}

Function Set-BalancedPerformancePlan {
    Write-Log -Level ACTION -Message "Setting Balanced Power Plan (Windows Default)..."
    powercfg /setactive $config.PowerPlan.BalancedGuid | Out-Null
    Write-Log -Level SUCCESS -Message "Balanced Performance power plan activated." -Indent 1
}

Function View-PerGameTweaks {
    Write-Log -Level ACTION -Message "Viewing Per-Game Optimizations..."
    $paths = @{
        "GPU Priority" = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences";
        "Fullscreen Optimizations" = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
    }
    foreach ($p in $paths.GetEnumerator()) {
        Write-Log -Level INFO -Message "Tweaks for: $($p.Name)" -Indent 1
        $items = Get-ItemProperty -Path $p.Value -ErrorAction SilentlyContinue
        if ($items) {
            $items.PSObject.Properties | ForEach-Object { 
                if ($_.Name -like "*.exe") {
                    Write-Log -Level INFO -Message "$([System.IO.Path]::GetFileName($_.Name)): ($($_.Value))" -Indent 2
                }
            }
        } else {
            Write-Log -Level INFO -Message "No tweaks found." -Indent 2
        }
    }
}

Function Remove-PerGameTweak {
    Write-Log -Level ACTION -Message "Remove a Per-Game Optimization..."
    $paths = @{
        "1" = @{ Name = "GPU Priority"; Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" };
        "2" = @{ Name = "Fullscreen Optimizations"; Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" }
    }
    $choice = Read-Host "Which tweak type to remove? (1) GPU Priority (2) Fullscreen Optimizations"
    if (-not $paths.ContainsKey($choice)) { Write-Log -Level ERROR -Message "Invalid choice."; return }

    $tweakType = $paths[$choice]
    $items = Get-ItemProperty -Path $tweakType.Path -ErrorAction SilentlyContinue | Select-Object -Property "*exe"
    if (-not $items) { Write-Log -Level INFO -Message "No tweaks of this type found."; return }
    
    $exeList = @{}
    $i = 1
    $items.PSObject.Properties | ForEach-Object { $exeList[$i] = $_.Name; Write-Host "  $i. $([System.IO.Path]::GetFileName($_.Name))"; $i++ }
    
    $exeChoice = Read-Host "Enter the number of the tweak to remove (or any other key to cancel)"
    if ($exeList.ContainsKey($exeChoice)) {
        $exeToRemove = $exeList[$exeChoice]
        try {
            Remove-ItemProperty -Path $tweakType.Path -Name $exeToRemove -Force -ErrorAction Stop
            Write-Log -Level SUCCESS -Message "Removed tweak for $([System.IO.Path]::GetFileName($exeToRemove))."
        } catch {
            Write-Log -Level ERROR -Message "Failed to remove tweak. Error: $($_.Exception.Message)"
        }
    } else { Write-Log -Level INFO -Message "Operation cancelled." }
}


#endregion

#region Main Execution

if ($PSBoundParameters.Keys.Count -gt 0) {
    Write-Log -Level INFO -Message "Running in non-interactive mode..."
    if ($CreateRestorePoint) { Create-SystemRestorePoint }
    if ($ApplyAll) { Invoke-AllOptimizations }
    if ($Restore) { Restore-BackedUpSettings }
    Write-Log -Level INFO -Message "Non-interactive tasks complete. Exiting script."
    exit
}

Function Show-Menu {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Magenta
    Write-Host "      Windows Gaming Performance Optimizer v4.0" -ForegroundColor White
    Write-Host "==================================================" -ForegroundColor Magenta
    
    Write-Host "`n--- System Setup & Global Actions ---" -ForegroundColor Yellow
    Write-Host "  1. Create System Restore Point (HIGHLY RECOMMENDED)" -ForegroundColor Green
    Write-Host "  2. Apply ALL Global Optimizations (Recommended First Step)"
    
    Write-Host "`n--- Individual Optimizations ---" -ForegroundColor Cyan
    Write-Host "  3. Set Ultimate Performance Power Plan"
    Write-Host "  4. Disable Unnecessary Services (e.g. Printer Spooler)"
    Write-Host "  5. Disable Mouse Acceleration"
    Write-Host "  6. Enable Hardware-accelerated GPU Scheduling (HAGS) (Reboot Required)"

    Write-Host "`n--- Per-Game Optimizations ---" -ForegroundColor Cyan
    Write-Host "  7. Set High GPU Priority for a Game"
    Write-Host "  8. Disable Fullscreen Optimizations for a Game"
    Write-Host "  9. View Applied Per-Game Tweaks"
    Write-Host "  A. Remove a Per-Game Tweak"

    Write-Host "`n--- Reversals (Undo) ---" -ForegroundColor DarkYellow
    Write-Host "  B. Re-enable Mouse Acceleration (Windows Default)"
    Write-Host "  C. Set Balanced Power Plan (Windows Default)"
    
    Write-Host "`n--- Full Recovery ---" -ForegroundColor Red
    Write-Host "  R. Restore ALL Settings from Initial Backup"
    Write-Host "  Q. Quit"
    Write-Host
}

$restartReason = $null
while ($true) {
    Show-Menu
    if ($restartReason) { Write-Host "`n! NOTE: $restartReason !" -ForegroundColor Yellow; $restartReason = $null }
    $choice = (Read-Host "Please enter your choice").ToUpper()

    switch ($choice) {
        "1" { Create-SystemRestorePoint }
        "2" { if ((Read-Host "Apply all safe, global optimizations? (Y/N)").ToLower() -eq 'y') { Invoke-AllOptimizations; $restartReason = "some changes require a restart to take full effect." } }
        "3" { Invoke-Backup; Set-UltimatePerformancePlan }
        "4" { Invoke-Backup; Disable-UnnecessaryServices; $restartReason = "disabling services is fully effective after a restart." }
        "5" { Write-Log -Level ACTION -Message "Applying Mouse Acceleration Tweaks..."; Apply-RegistryTweaks -Categories "Mouse" }
        "6" { Enable-HAGS; $restartReason = "enabling HAGS REQUIRES a restart." }
        "7" { Select-ExeAndApplyTweak -WindowTitle "Select Game for High GPU Priority" -RegistryPath "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" -Value "GpuPreference=2;" -SuccessMessage "Set High GPU preference for '{0}'." }
        "8" { Select-ExeAndApplyTweak -WindowTitle "Select Game to Disable Fullscreen Optimizations" -RegistryPath "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers" -Value "~ DISABLEDXMAXIMIZEDWINDOWEDMODE" -SuccessMessage "Disabled Fullscreen Optimizations for '{0}'." }
        "9" { View-PerGameTweaks }
        "A" { Remove-PerGameTweak }
        "B" { Revert-RegistryTweaksToDefault -Categories "Mouse" }
        "C" { Set-BalancedPerformancePlan }
        "R" { if ((Read-Host "This will restore your original settings from the initial backup. Are you sure? (Y/N)").ToLower() -eq 'y') { Restore-BackedUpSettings; $restartReason = "a restart is recommended to finalize restoration." } }
        "Q" { exit }
        default { Write-Warning "Invalid selection." }
    }
    Read-Host "`nPress Enter to return to the menu..."
}
#endregion