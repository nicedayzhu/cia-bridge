param(
    [string]$Repository = 'nicedayzhu/cia-bridge'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$secretRoot = Join-Path $projectRoot '.secrets'
$keystorePath = Join-Path $secretRoot 'android-release.p12'
$credentialsPath = Join-Path $secretRoot 'android-release-credentials.json'

if (Test-Path -LiteralPath $keystorePath) {
    throw "Signing key already exists: $keystorePath. Refusing to replace it."
}

$gh = Get-Command gh -ErrorAction Stop
$keytool = if ($env:JAVA_HOME) {
    Join-Path $env:JAVA_HOME 'bin\keytool.exe'
} else {
    (Get-Command keytool -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $keytool)) {
    throw "keytool not found: $keytool"
}

& $gh.Source auth status | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI is not authenticated.' }

New-Item -ItemType Directory -Path $secretRoot -Force | Out-Null
$passwordBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$password = [Convert]::ToBase64String($passwordBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$alias = 'cia_bridge'

& $keytool -genkeypair `
    -keystore $keystorePath `
    -storetype PKCS12 `
    -storepass $password `
    -keypass $password `
    -alias $alias `
    -keyalg RSA `
    -keysize 4096 `
    -validity 10000 `
    -dname 'CN=CIA Bridge, OU=Release, O=nicedayzhu, C=CN'
if ($LASTEXITCODE -ne 0) { throw 'keytool failed.' }

$credentials = [ordered]@{
    repository = $Repository
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    keystore = $keystorePath
    alias = $alias
    storePassword = $password
    keyPassword = $password
}
$credentials | ConvertTo-Json | Set-Content -LiteralPath $credentialsPath -Encoding UTF8

function Set-GitHubSecret([string]$Name, [string]$Value) {
    $Value | & $gh.Source secret set $Name --repo $Repository
    if ($LASTEXITCODE -ne 0) { throw "Failed to set GitHub secret: $Name" }
}

$keystoreBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystorePath))
Set-GitHubSecret 'ANDROID_KEYSTORE_BASE64' $keystoreBase64
Set-GitHubSecret 'ANDROID_KEYSTORE_PASSWORD' $password
Set-GitHubSecret 'ANDROID_KEY_ALIAS' $alias
Set-GitHubSecret 'ANDROID_KEY_PASSWORD' $password

Write-Host "Android release signing is configured for $Repository."
Write-Host "Back up this ignored directory securely: $secretRoot"
