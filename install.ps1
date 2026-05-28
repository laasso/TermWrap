<#
.SYNOPSIS
    TermWrap installer / uninstaller.

.DESCRIPTION
    Downloads the latest TermWrap release from GitHub, copies the DLLs to
    "%ProgramFiles%\RDP Wrapper\", merges the registry, and (by default)
    applies the group policy registry keys required for USB redirection.

.EXAMPLE
    # One-liner install (run in an elevated PowerShell):
    irm https://raw.githubusercontent.com/laasso/TermWrap/master/install.ps1 | iex

.EXAMPLE
    # Explicit invocation with options:
    iex "& { $(irm https://raw.githubusercontent.com/laasso/TermWrap/master/install.ps1) } -SkipUsbPolicy"

.EXAMPLE
    # Uninstall:
    iex "& { $(irm https://raw.githubusercontent.com/laasso/TermWrap/master/install.ps1) } -Action Uninstall"
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action = 'Install',
    [switch]$SkipUsbPolicy,
    [switch]$NoRestart,
    [string]$Repo = 'laasso/TermWrap'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$InstallDir = Join-Path $env:ProgramFiles 'RDP Wrapper'

function Assert-Admin {
    $id        = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$id
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell (Run as Administrator).'
    }
}

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        'x86'   { 'x86' }
        default { throw "Unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }
}

function Get-ReleaseAssets {
    param([string]$DestDir)

    $arch = Get-Arch
    $api  = "https://api.github.com/repos/$Repo/releases/latest"
    Write-Host "Querying latest release of $Repo..." -ForegroundColor Cyan
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'TermWrap-Installer' }

    $asset = $rel.assets |
        Where-Object { $_.name -match $arch -and $_.name -match '\.zip$' } |
        Select-Object -First 1

    if (-not $asset) {
        throw "No release asset matching '$arch*.zip' found in latest release ($($rel.tag_name))."
    }

    $zip = Join-Path $DestDir $asset.name
    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size/1KB)) KB)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $DestDir -Force
    Remove-Item $zip -Force
}

function Set-PolicyValue {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Apply-UsbPolicies {
    Write-Host 'Applying USB redirection group policies...' -ForegroundColor Cyan

    # "Allow remote access to the Plug and Play interface" -> Enabled
    Set-PolicyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' 'AllowRemoteRPC' 1

    # "Do not allow supported Plug and Play device redirection" -> Disabled
    Set-PolicyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' 'fDisablePNPRedir' 0

    # "Allow RDP redirection of other supported RemoteFX USB devices ..." -> Enabled (Admins+Users)
    Set-PolicyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client' 'fUsbRedirectionEnableMode' 2
}

function Stop-RdpServices {
    # TermService holds TermWrap.dll open. Stopping it with -Force takes down
    # dependents (UmRdpService, SessionEnv, etc). Save their state so we can
    # restart the same ones afterward.
    $svc = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if (-not $svc) { return @() }
    $dependents = @(Get-Service -Name 'TermService' -DependentServices |
                    Where-Object { $_.Status -eq 'Running' } |
                    Select-Object -ExpandProperty Name)
    Write-Host 'Stopping TermService (and dependents)...' -ForegroundColor Cyan
    Stop-Service -Name 'TermService' -Force -ErrorAction Stop
    return ,@('TermService') + $dependents
}

function Start-RdpServices {
    param([string[]]$Services)
    if (-not $Services) { return }
    foreach ($n in $Services) {
        Write-Host "Starting $n..." -ForegroundColor Cyan
        Start-Service -Name $n -ErrorAction SilentlyContinue
    }
}

function Find-OrThrow {
    param([string]$Root, [string]$Filter)
    $f = Get-ChildItem $Root -Recurse -Filter $Filter -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $f) { throw "Required file not found in release: $Filter" }
    return $f.FullName
}

function Invoke-Install {
    Assert-Admin

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir | Out-Null
    }

    $tmp = Join-Path $env:TEMP "TermWrap_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmp | Out-Null

    $stopped = @()
    try {
        Get-ReleaseAssets -DestDir $tmp

        $term  = Find-OrThrow $tmp 'TermWrap.dll'
        $um    = Find-OrThrow $tmp 'UmWrap.dll'
        $zydis = Find-OrThrow $tmp 'Zydis.dll'
        $reg   = Find-OrThrow $tmp 'Install_termwrap_umwrap.reg'

        $stopped = Stop-RdpServices

        Write-Host 'Merging registry...' -ForegroundColor Cyan
        $p = Start-Process -FilePath reg.exe -ArgumentList @('import', "`"$reg`"") -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw "reg.exe import failed with exit code $($p.ExitCode)." }

        Write-Host "Copying DLLs to $InstallDir..." -ForegroundColor Cyan
        Copy-Item $term, $um, $zydis -Destination $InstallDir -Force

        if (-not $SkipUsbPolicy) { Apply-UsbPolicies }
    }
    finally {
        Start-RdpServices -Services $stopped
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host 'TermWrap installed. TermService has been restarted; a full reboot is recommended but not required.' -ForegroundColor Green

    if (-not $NoRestart) {
        $r = Read-Host 'Reboot now? [y/N]'
        if ($r -match '^[Yy]') { Restart-Computer -Force }
    }
}

function Invoke-Uninstall {
    Assert-Admin

    $tmp = Join-Path $env:TEMP "TermWrap_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmp | Out-Null

    $stopped = @()
    try {
        Get-ReleaseAssets -DestDir $tmp
        $reg = Find-OrThrow $tmp 'Revert_to_default.reg'

        $stopped = Stop-RdpServices

        Write-Host 'Reverting registry...' -ForegroundColor Cyan
        Start-Process -FilePath reg.exe -ArgumentList @('import', "`"$reg`"") -Wait -NoNewWindow

        if (Test-Path $InstallDir) {
            Write-Host "Removing $InstallDir..." -ForegroundColor Cyan
            Remove-Item $InstallDir -Recurse -Force
        }
    }
    finally {
        Start-RdpServices -Services $stopped
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'TermWrap uninstalled. Reboot required.' -ForegroundColor Green
    if (-not $NoRestart) {
        $r = Read-Host 'Reboot now? [y/N]'
        if ($r -match '^[Yy]') { Restart-Computer -Force }
    }
}

switch ($Action) {
    'Install'   { Invoke-Install }
    'Uninstall' { Invoke-Uninstall }
}
