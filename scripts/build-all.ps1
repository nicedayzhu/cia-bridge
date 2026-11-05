param(
    [switch]$Clean,
    [switch]$SkipWindows,
    [switch]$SkipAndroid
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$localFlutter = Join-Path $projectRoot '.toolchains\flutter-sdk\flutter\bin\flutter.bat'
$flutter = if ($env:CIA_BRIDGE_FLUTTER) { $env:CIA_BRIDGE_FLUTTER } else { $localFlutter }

if (-not (Test-Path -LiteralPath $flutter)) {
    throw "Flutter not found: $flutter. Set CIA_BRIDGE_FLUTTER to flutter.bat."
}

$env:PUB_CACHE = Join-Path $projectRoot '.toolchains\pub-cache'
$env:GRADLE_USER_HOME = Join-Path $projectRoot '.toolchains\gradle-cache'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'

if (-not $SkipAndroid) {
    if (-not $env:ANDROID_HOME) {
        $env:ANDROID_HOME = 'F:\work\music_online_apk\.toolchains\android-sdk'
    }
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    if (-not $env:JAVA_HOME) {
        $env:JAVA_HOME = 'F:\work\music_online_apk\.toolchains\jdk17'
    }
}

Push-Location $projectRoot
try {
    if ($Clean) {
        & $flutter clean
        if ($LASTEXITCODE -ne 0) { throw 'flutter clean failed' }
    }

    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
    & $flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze failed' }
    & $flutter test
    if ($LASTEXITCODE -ne 0) { throw 'flutter test failed' }

    if (-not $SkipWindows) {
        & $flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    }
    if (-not $SkipAndroid) {
        & $flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    }

    $distRoot = Join-Path $projectRoot 'dist'
    if (Test-Path -LiteralPath $distRoot) {
        Remove-Item -LiteralPath $distRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $distRoot | Out-Null

    if (-not $SkipWindows) {
        $windowsSource = Join-Path $projectRoot 'build\windows\x64\runner\Release'
        $windowsTarget = Join-Path $distRoot 'windows\CIA-Bridge-Windows-x64'
        New-Item -ItemType Directory -Path $windowsTarget -Force | Out-Null
        Copy-Item -Path (Join-Path $windowsSource '*') -Destination $windowsTarget -Recurse -Force
        Compress-Archive -Path (Join-Path $windowsTarget '*') -DestinationPath (Join-Path $distRoot 'CIA-Bridge-Windows-x64.zip') -CompressionLevel Optimal
    }

    if (-not $SkipAndroid) {
        $androidTarget = Join-Path $distRoot 'android'
        New-Item -ItemType Directory -Path $androidTarget -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk') -Destination (Join-Path $androidTarget 'CIA-Bridge-Android-release.apk')
    }

    Write-Host "Artifacts: $distRoot"
}
finally {
    Pop-Location
}
