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
    $javaHome = if ($env:CIA_BRIDGE_JAVA_HOME) {
        $env:CIA_BRIDGE_JAVA_HOME
    } else {
        'F:\work\music_online_apk\.toolchains\jdk17'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe'))) {
        throw "JDK 17 was not found: $javaHome. Set CIA_BRIDGE_JAVA_HOME to a JDK 17+ directory."
    }
    # Gradle 9 requires Java 17+. Never inherit a system-wide Java 8 JAVA_HOME.
    $env:JAVA_HOME = $javaHome
    $env:Path = "$(Join-Path $env:JAVA_HOME 'bin');$env:Path"
}

$hasAndroidReleaseSigning = if ($SkipAndroid) { $false } else {
    $androidSigningValues = @(
        $env:CIA_BRIDGE_KEYSTORE_PATH,
        $env:CIA_BRIDGE_KEYSTORE_PASSWORD,
        $env:CIA_BRIDGE_KEY_ALIAS,
        $env:CIA_BRIDGE_KEY_PASSWORD
    )
    @($androidSigningValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq $androidSigningValues.Count
}

Push-Location $projectRoot
try {
    $pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
    if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$') {
        throw 'Could not read a semantic version from pubspec.yaml.'
    }
    $releaseVersion = $Matches[1]

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
        & $flutter build windows --release "--dart-define=APP_VERSION=$releaseVersion"
        if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    }
    if (-not $SkipAndroid) {
        & $flutter build apk --release "--dart-define=APP_VERSION=$releaseVersion"
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
        if (-not $hasAndroidReleaseSigning) {
            Write-Warning 'Android release credentials are not set; packaging a debug-signed local test APK.'
        }
    }

    $distRoot = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $distRoot -Force | Out-Null

    if (-not $SkipWindows) {
        $windowsSource = Join-Path $projectRoot 'build\windows\x64\runner\Release'
        $windowsRoot = Join-Path $distRoot 'windows'
        $windowsTarget = Join-Path $distRoot "windows\CIA-Bridge-v$releaseVersion-Windows-x64"
        $windowsArchive = Join-Path $distRoot "CIA-Bridge-v$releaseVersion-Windows-x64.zip"
        if (Test-Path -LiteralPath $windowsRoot) {
            Remove-Item -LiteralPath $windowsRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $windowsArchive) {
            Remove-Item -LiteralPath $windowsArchive -Force
        }
        New-Item -ItemType Directory -Path $windowsTarget -Force | Out-Null
        Copy-Item -Path (Join-Path $windowsSource '*') -Destination $windowsTarget -Recurse -Force
        Compress-Archive -Path (Join-Path $windowsTarget '*') -DestinationPath $windowsArchive -CompressionLevel Optimal
    }

    if (-not $SkipAndroid) {
        $androidTarget = Join-Path $distRoot 'android'
        if (Test-Path -LiteralPath $androidTarget) {
            Remove-Item -LiteralPath $androidTarget -Recurse -Force
        }
        New-Item -ItemType Directory -Path $androidTarget -Force | Out-Null
        $androidName = if ($hasAndroidReleaseSigning) {
            "CIA-Bridge-v$releaseVersion-Android.apk"
        } else {
            "CIA-Bridge-v$releaseVersion-Android-local-test.apk"
        }
        Copy-Item -LiteralPath (Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk') -Destination (Join-Path $androidTarget $androidName)
    }

    Write-Host "Artifacts: $distRoot"
}
finally {
    Pop-Location
}
