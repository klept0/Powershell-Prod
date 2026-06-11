<# 
.SYNOPSIS
  Safer Windows Update helper for Windows 10/11.

.DESCRIPTION
  Installs/imports PSWindowsUpdate, optionally registers Microsoft Update,
  scans or installs updates, logs actions, and only reboots when explicitly allowed.

.EXAMPLES
  .\Windows_Update_Improved.ps1 -ScanOnly
  .\Windows_Update_Improved.ps1 -Install
  .\Windows_Update_Improved.ps1 -Install -AutoReboot
  .\Windows_Update_Improved.ps1 -Install -IncludeDrivers
  .\Windows_Update_Improved.ps1 -ResetWUComponents
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$ScanOnly,
    [switch]$Install,
    [switch]$AutoReboot,
    [switch]$IncludeDrivers,
    [switch]$ResetWUComponents,
    [switch]$UseMicrosoftUpdate = $true,
    [string]$LogDirectory = "$env:ProgramData\WindowsUpdateScript\Logs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Relaunch-AsAdmin {
    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
    )

    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ($value) { $argList += "-$key" }
        }
        else {
            $argList += "-$key"
            $argList += "`"$value`""
        }
    }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Ensure-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Warning "Could not force TLS 1.2. Continuing anyway. $($_.Exception.Message)"
    }
}

function Ensure-PSGallery {
    $repo = Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue
    if (-not $repo) {
        Write-Section "Registering PSGallery"
        Register-PSRepository -Default
    }
}

function Ensure-NuGetProvider {
    $provider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
    if (-not $provider -or $provider.Version -lt [version]'2.8.5.201') {
        Write-Section "Installing NuGet package provider"
        Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force | Out-Null
    }
}

function Ensure-PSWindowsUpdate {
    Write-Section "Checking PSWindowsUpdate module"

    $module = Get-Module -ListAvailable -Name PSWindowsUpdate | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $module) {
        Ensure-Tls12
        Ensure-PSGallery
        Ensure-NuGetProvider

        $repo = Get-PSRepository -Name 'PSGallery'
        $originalPolicy = $repo.InstallationPolicy

        try {
            if ($originalPolicy -ne 'Trusted') {
                Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
            }

            Install-Module -Name PSWindowsUpdate -Scope AllUsers -Force -AllowClobber -Confirm:$false
        }
        finally {
            if ($originalPolicy -and $originalPolicy -ne 'Trusted') {
                Set-PSRepository -Name 'PSGallery' -InstallationPolicy $originalPolicy
            }
        }
    }

    Import-Module PSWindowsUpdate -Force
    $loaded = Get-Module PSWindowsUpdate
    Write-Host "Loaded PSWindowsUpdate $($loaded.Version)"
}

function Ensure-MicrosoftUpdateService {
    if (-not $UseMicrosoftUpdate) { return }

    Write-Section "Checking Microsoft Update service"
    $services = Get-WUServiceManager
    $mu = $services | Where-Object { $_.Name -eq 'Microsoft Update' }

    if (-not $mu) {
        Write-Host "Adding Microsoft Update service so Office/Edge/.NET/etc. can be included."
        Add-WUServiceManager -MicrosoftUpdate -Confirm:$false | Out-Null
    }
    else {
        Write-Host "Microsoft Update service already registered."
    }
}

function Show-RebootStatus {
    Write-Section "Reboot status"
    try {
        $reboot = Get-WURebootStatus -Silent
        if ($reboot) {
            Write-Warning "A reboot is required."
        }
        else {
            Write-Host "No reboot currently required."
        }
    }
    catch {
        Write-Warning "Could not determine reboot status. $($_.Exception.Message)"
    }
}

if (-not (Test-IsAdmin)) {
    Relaunch-AsAdmin
}

if (-not $ScanOnly -and -not $Install -and -not $ResetWUComponents) {
    $ScanOnly = $true
}

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDirectory "WindowsUpdate-$timestamp.log"

Start-Transcript -Path $logFile -Append | Out-Null

try {
    Write-Section "System"
    Write-Host "Computer: $env:COMPUTERNAME"
    Write-Host "User: $env:USERNAME"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "OS: $((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).Version)"
    Write-Host "Log: $logFile"

    Ensure-PSWindowsUpdate
    Ensure-MicrosoftUpdateService

    if ($ResetWUComponents) {
        Write-Section "Resetting Windows Update components"
        Reset-WUComponents -Verbose
    }

    $commonParams = @{
        MicrosoftUpdate = [bool]$UseMicrosoftUpdate
        AcceptAll       = $true
        IgnoreReboot    = -not $AutoReboot
        Verbose         = $true
    }

    if (-not $IncludeDrivers) {
        $commonParams['NotCategory'] = 'Drivers'
    }

    if ($ScanOnly) {
        Write-Section "Available updates"
        $scanParams = @{
            MicrosoftUpdate = [bool]$UseMicrosoftUpdate
            Verbose         = $true
        }

        if (-not $IncludeDrivers) {
            $scanParams['NotCategory'] = 'Drivers'
        }

        $updates = Get-WindowsUpdate @scanParams

        if (-not $updates) {
            Write-Host "No applicable updates found."
        }
        else {
            $updates | Select-Object KB, Size, Title | Format-Table -AutoSize
            Write-Host ""
            Write-Host "Scan only. Nothing installed."
        }
    }

    if ($Install) {
        Write-Section "Installing updates"
        if ($AutoReboot) {
            Write-Warning "AutoReboot is enabled. The machine may restart automatically."
            $commonParams.Remove('IgnoreReboot')
            $commonParams['AutoReboot'] = $true
        }
        else {
            Write-Host "AutoReboot is disabled. Reboot manually if required."
        }

        Install-WindowsUpdate @commonParams
    }

    Show-RebootStatus
}
catch {
    Write-Error "Windows Update script failed: $($_.Exception.Message)"
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
