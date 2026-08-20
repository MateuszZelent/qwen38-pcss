[CmdletBinding()]
param(
    [ValidateSet('Install', 'Status', 'Restore')]
    [string]$Action = 'Install',
    [string]$VllmBaseUrl = 'http://127.0.0.1:18000/v1',
    [string]$DeepSeekBaseUrl = 'http://127.0.0.1:18001/v1',
    [string]$KimiBaseUrl = 'http://127.0.0.1:18002/v1',
    [string]$OrnithBaseUrl = 'http://127.0.0.1:18003/v1',
    [string]$Ornith397BaseUrl = 'http://127.0.0.1:18004/v1',
    [int]$RouterPort = 8765,
    [switch]$SkipDesktopPatch
)

$ErrorActionPreference = 'Stop'
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = $HOME }
$ProjectDir = Split-Path -Parent $PSScriptRoot
$VendorDir = Join-Path $ProjectDir 'vendor\codex-shim'
$SettingsDir = Join-Path $UserHome '.codex-shim'
$SettingsPath = Join-Path $SettingsDir 'models.json'
$DesktopTool = Join-Path $ProjectDir 'tools\manage-codex-desktop.mjs'

function Find-Python {
    if ($env:CODEX_ROUTER_PYTHON -and (Test-Path $env:CODEX_ROUTER_PYTHON)) {
        return $env:CODEX_ROUTER_PYTHON
    }
    foreach ($candidate in @(
        (Join-Path $UserHome 'miniconda3\python.exe'),
        (Join-Path $UserHome 'AppData\Local\Programs\Python\Python312\python.exe')
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    $bundled = Join-Path $UserHome '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path $bundled) { return $bundled }
    $bundled = Get-ChildItem (Join-Path $UserHome '.cache\codex-runtimes') -Filter python.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\dependencies\\python\\python\.exe$' } |
        Select-Object -First 1 -ExpandProperty FullName
    if ($bundled) { return $bundled }
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'Nie znaleziono Python 3.11+. Ustaw CODEX_ROUTER_PYTHON na pelna sciezke do python.exe.'
}

function Invoke-Shim([string[]]$Arguments) {
    $oldPythonPath = $env:PYTHONPATH
    try {
        $env:PYTHONPATH = if ($oldPythonPath) { "$VendorDir;$oldPythonPath" } else { $VendorDir }
        & $script:Python -m codex_shim.cli --settings $SettingsPath --port $RouterPort @Arguments
        if (-not $?) { throw 'codex-shim nie uruchomil sie poprawnie' }
    } finally {
        $env:PYTHONPATH = $oldPythonPath
    }
}

$script:Python = Find-Python
Write-Host "Python routera: $script:Python"
& $script:Python --version

if ($Action -eq 'Restore') {
    Invoke-Shim @('disable')
    if (-not $SkipDesktopPatch) {
        $node = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($node) { & $node.Source $DesktopTool restore }
    }
    Write-Host 'Przywrocono konfiguracje Codex sprzed instalacji routera.'
    exit 0
}

if ($Action -eq 'Status') {
    Invoke-Shim @('doctor')
    exit 0
}

& $script:Python -c 'import aiohttp' 2>$null
if ($LASTEXITCODE -ne 0) {
    & $script:Python -m pip install --user 'aiohttp>=3.9'
    if ($LASTEXITCODE -ne 0) { throw 'Nie udalo sie zainstalowac aiohttp.' }
}

New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
$settings = Get-Content -Raw (Join-Path $ProjectDir 'config\codex-router-models.json.example') | ConvertFrom-Json
foreach ($model in $settings.models) {
    if ($model.slug -eq 'qwen3.8-27b') {
        $model.base_url = $VllmBaseUrl.TrimEnd('/')
    } elseif ($model.slug -eq 'deepseek-v4-pro') {
        $model.base_url = $DeepSeekBaseUrl.TrimEnd('/')
    } elseif ($model.slug -eq 'kimi-k3') {
        $model.base_url = $KimiBaseUrl.TrimEnd('/')
    } elseif ($model.slug -eq 'ornith-1.5-35b') {
        $model.base_url = $OrnithBaseUrl.TrimEnd('/')
    } elseif ($model.slug -eq 'ornith-1.5-397b') {
        $model.base_url = $Ornith397BaseUrl.TrimEnd('/')
    }
}
$settings | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 $SettingsPath

Invoke-Shim @('enable')
Invoke-Shim @('doctor')

if (-not $SkipDesktopPatch) {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Warning 'Nie znaleziono node.exe. Router dziala, ale Qwen moze byc ukryty w selektorze Desktop.'
    } else {
        Write-Host 'Zamknij Codex Desktop przed zastosowaniem poprawki selektora.'
        & $node.Source $DesktopTool patch
        if ($LASTEXITCODE -ne 0) { throw 'Nie udalo sie zastosowac odwracalnej poprawki Codex Desktop.' }
    }
}

Write-Host "Router dziala na http://127.0.0.1:$RouterPort/v1"
Write-Host 'Uruchom ponownie Codex Desktop. GPT, Qwen, DeepSeek, Kimi i Ornith powinny byc dostepne z jednej listy.'
