<#
.SYNOPSIS
  Configura (o rota) los secretos de firma de VibeGrab en GitHub Actions.

.DESCRIPTION
  Sube la clave de firma y sus contrasenas a los secretos del repositorio,
  cifradas con la clave publica del repo (sealed box). Asi el APK se compila y
  firma en GitHub, sin depender de ningun portatil, y la clave nunca queda en
  el codigo.

  Se ejecuta desde cualquier PC que tenga el keystore y Python con `pynacl`.

.EXAMPLE
  python -m pip install pynacl
  powershell -File tools/set-signing-secrets.ps1 -Keystore C:\clave\vibegrab.jks

.EXAMPLE
  # Rota la clave con un keystore nuevo
  powershell -File tools/set-signing-secrets.ps1 -Keystore C:\clave\nueva.jks -Alias vibegrab
#>
param(
  [string]$Repo = "44JACK44-cmd/vibeGrab",
  [string]$Keystore = "mobile/android/keystore/vibegrab-release.jks",
  [string]$KeyProperties = "mobile/android/key.properties",
  [string]$Alias = "vibegrab",
  [string]$StorePassword,
  [string]$KeyPassword,
  [string]$Python
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $root $Path)
}

$Keystore = Resolve-RepoPath $Keystore
$KeyProperties = Resolve-RepoPath $KeyProperties

if (-not (Test-Path $Keystore)) { throw "No encuentro el keystore: $Keystore" }

# Contrasenas: parametros > variables de entorno > key.properties local.
if (-not $StorePassword -or -not $KeyPassword) {
  if (Test-Path $KeyProperties) {
    $props = @{}
    foreach ($line in Get-Content $KeyProperties) {
      if ($line -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $props[$Matches[1]] = $Matches[2].Trim() }
    }
    if (-not $StorePassword) { $StorePassword = $props['storePassword'] }
    if (-not $KeyPassword) { $KeyPassword = $props['keyPassword'] }
    if ($props['keyAlias']) { $Alias = $props['keyAlias'] }
  }
}
if (-not $StorePassword) { $StorePassword = Read-Host 'Contrasena del keystore' -AsSecureString | ConvertFrom-SecureString -AsPlainText }
if (-not $KeyPassword) { $KeyPassword = $StorePassword }

# Token de GitHub: variable de entorno o credencial guardada por git.
$token = $env:GITHUB_TOKEN
if (-not $token) {
  $cred = ("protocol=https`nhost=github.com`n`n" | git credential fill 2>$null)
  $token = ($cred -split "`n" | Where-Object { $_ -like 'password=*' }) -replace '^password=', ''
}
if (-not $token) { throw "Sin token de GitHub (define GITHUB_TOKEN o configura git credential)." }

# Python con pynacl (venv del backend > python del sistema).
if (-not $Python) {
  $candidates = @(
    (Join-Path $root 'backend/.venv/Scripts/python.exe'),
    'python',
    'py'
  )
  foreach ($candidate in $candidates) {
    try {
      if ((Get-Command $candidate -ErrorAction SilentlyContinue) -or (Test-Path $candidate)) {
        & $candidate -c 'import nacl' 2>$null
        if ($LASTEXITCODE -eq 0) { $Python = $candidate; break }
      }
    } catch { }
  }
  if (-not $Python) { throw "Necesito Python con 'pynacl'. Ejecuta: python -m pip install pynacl" }
}

# Huella SHA-256 del certificado (para ANDROID_CERT_SHA256).
$certSha256 = $null
$keytool = Get-Command keytool -ErrorAction SilentlyContinue
if ($keytool) {
  $out = & $keytool.Source -list -v -keystore $Keystore -alias $Alias -storepass $StorePassword 2>&1 | Out-String
  $m = [regex]::Match($out, 'SHA256:\s*([0-9A-Fa-f:]{60,})')
  if ($m.Success) { $certSha256 = ($m.Groups[1].Value -replace ':', '').ToLower() }
}

$secretBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Keystore))
$payload = [ordered]@{
  ANDROID_KEYSTORE_BASE64   = $secretBase64
  ANDROID_KEYSTORE_PASSWORD = $StorePassword
  ANDROID_KEY_PASSWORD      = $KeyPassword
  ANDROID_KEY_ALIAS         = $Alias
}
if ($certSha256) { $payload['ANDROID_CERT_SHA256'] = $certSha256 }

Write-Host "Keystore : $Keystore"
Write-Host "Alias    : $Alias"
if ($certSha256) { Write-Host "SHA-256  : $certSha256" }
Write-Host "Repo     : $Repo"
Write-Host ""

$env:GITHUB_TOKEN = $token
$env:GITHUB_REPO = $Repo
$env:SECRETS_JSON = ($payload | ConvertTo-Json -Compress)

& $Python (Join-Path $root 'tools/gh_secrets.py')
