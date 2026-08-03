#!/usr/bin/env pwsh
<#
.SYNOPSIS
Build and install relate on Windows.

.DESCRIPTION
Builds the package, places relate.exe in a per-user directory, adds that
directory to the user PATH, and builds the local atlas unless -NoIndex is set.
The install is idempotent and requires no elevation.

.PARAMETER Prefix
Install directory. Defaults to %LOCALAPPDATA%\Programs\relate.

.PARAMETER NoIndex
Skip `relate index`. Queries still work through the live path.

.EXAMPLE
.\install.ps1
.EXAMPLE
.\install.ps1 -Prefix C:\tools\bin -NoIndex
#>
[CmdletBinding()]
param(
    [string] $Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\relate'),
    [switch] $NoIndex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot

function Write-Note { param([string] $Message) Write-Host "$([char]0x2713)  $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host "!  $Message" -ForegroundColor Yellow }

function Remove-Placed {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Force
        return $true
    } catch {
        $aside = "$Path.old-$PID"
        try {
            Move-Item -LiteralPath $Path -Destination $aside -Force
            Remove-Item -LiteralPath $aside -Force -ErrorAction SilentlyContinue
            return $true
        } catch {
            Write-Warn "$Path is in use and could not be replaced"
            return $false
        }
    }
}

function Place-Binary {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    if (-not (Remove-Placed $Destination)) { return $null }
    try {
        New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
        return 'link'
    } catch {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return 'copy'
    }
}

$zig = Get-Command zig -ErrorAction SilentlyContinue
if (-not $zig) {
    Write-Warn 'zig is not installed; install the minimum_zig_version declared by build.zig.zon'
    exit 1
}

Write-Host 'building relate...'
Push-Location $root
try {
    & $zig.Source build
    if ($LASTEXITCODE -ne 0) { throw "zig build exited $LASTEXITCODE" }
} finally {
    Pop-Location
}

$source = Join-Path $root 'zig-out\bin\relate.exe'
if (-not (Test-Path -LiteralPath $source)) { throw "$source missing after build" }

Get-ChildItem -Path $Prefix -Filter 'relate.exe.old-*' -Force -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
$destination = Join-Path $Prefix 'relate.exe'
$how = Place-Binary -Source $source -Destination $destination
if (-not $how) { throw "could not place relate.exe at $Prefix" }
Write-Note "relate.exe -> $Prefix ($how)"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$normalizedPrefix = $Prefix.TrimEnd('\')
$entries = $userPath -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
if ($entries -notcontains $normalizedPrefix) {
    $joined = if ([string]::IsNullOrEmpty($userPath)) { $Prefix } else { "$($userPath.TrimEnd(';'));$Prefix" }
    [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
    Write-Note 'added the install directory to your user PATH (new terminals pick it up)'
}
if (($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') }) -notcontains $normalizedPrefix) {
    $env:Path = "$env:Path;$Prefix"
}

& $destination --version
if ($LASTEXITCODE -ne 0) { throw "installed relate.exe exited $LASTEXITCODE" }

if (-not $NoIndex) {
    & $destination index
    if ($LASTEXITCODE -ne 0) { throw "relate index exited $LASTEXITCODE" }
    & $destination status
}
