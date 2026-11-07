param(
    [switch]$SkipWindows,
    [switch]$SkipAndroid
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterRoot = Join-Path $projectRoot '.toolchains\flutter-sdk\flutter'
$dartSdk = Join-Path $flutterRoot 'bin\cache\dart-sdk'
$dart = Join-Path $dartSdk 'bin\dart.exe'
$aotRuntime = Join-Path $dartSdk 'bin\dartaotruntime.exe'
$frontend = Join-Path $dartSdk 'bin\snapshots\frontend_server_aot.dart.snapshot'
$patchedSdk = Join-Path $flutterRoot 'bin\cache\artifacts\engine\common\flutter_patched_sdk_product'
$packageConfig = Join-Path $projectRoot '.dart_tool\package_config.json'
$mainDart = Join-Path $projectRoot 'lib\main.dart'

foreach ($required in @($dart, $aotRuntime, $frontend, $patchedSdk, $mainDart)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required build input not found: $required"
    }
}

$pubspec = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$') {
    throw 'Could not read the version from pubspec.yaml.'
}
$releaseVersion = $Matches[1]
$buildNumber = if ($Matches[2]) { $Matches[2] } else { '1' }
$versionParts = $releaseVersion.Split('.')
$flutterVersion = Get-Content -LiteralPath (Join-Path $flutterRoot 'bin\cache\flutter.version.json') -Raw | ConvertFrom-Json

$env:PUB_CACHE = Join-Path $projectRoot '.toolchains\pub-cache'
$env:GRADLE_USER_HOME = Join-Path $projectRoot '.toolchains\gradle-cache'
$env:APPDATA = Join-Path $projectRoot '.toolchains\appdata'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null

Push-Location $projectRoot
try {
    & $dart pub --suppress-analytics get --offline --example --directory $projectRoot
    if ($LASTEXITCODE -ne 0) { throw 'dart pub get failed' }

    function Invoke-KernelCompile {
        param([string]$TargetOs, [string]$BuildDirectory)

        New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
        $recordedUses = Join-Path $BuildDirectory 'recorded_uses.json'
        $args = @(
            $frontend,
            '--sdk-root', "$patchedSdk\",
            '--target=flutter',
            '--no-print-incremental-dependencies',
            "-DFLUTTER_BUILD_NAME=$releaseVersion",
            "-DFLUTTER_BUILD_NUMBER=$buildNumber",
            "-DFLUTTER_VERSION=$($flutterVersion.frameworkVersion)",
            "-DFLUTTER_CHANNEL=$($flutterVersion.channel)",
            "-DFLUTTER_GIT_URL=$($flutterVersion.repositoryUrl)",
            "-DFLUTTER_FRAMEWORK_REVISION=$($flutterVersion.frameworkRevision)",
            "-DFLUTTER_ENGINE_REVISION=$($flutterVersion.engineRevision)",
            "-DFLUTTER_DART_VERSION=$($flutterVersion.dartSdkVersion)",
            '-Ddart.vm.profile=false',
            '-Ddart.vm.product=true',
            '--delete-tostring-package-uri=dart:ui',
            '--delete-tostring-package-uri=package:flutter',
            '--aot', '--tfa', '--target-os', $TargetOs,
            '--packages', $packageConfig,
            '--output-dill', (Join-Path $BuildDirectory 'app.dill'),
            '--depfile', (Join-Path $BuildDirectory 'kernel_snapshot_program.d'),
            "--recorded-uses=$recordedUses",
            '--verbosity=error',
            '--enable-experiment=alternative-invalidation-strategy',
            $mainDart
        )
        & $aotRuntime @args
        if ($LASTEXITCODE -ne 0) { throw "$TargetOs kernel compilation failed" }
    }

    function Copy-FlutterAssets {
        param([string]$AssetRoot)

        Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\fonts\NotoSansSC-CIABridge.ttf') `
            -Destination (Join-Path $AssetRoot 'assets\fonts\NotoSansSC-CIABridge.ttf') -Force
        Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\data\title_database.json') `
            -Destination (Join-Path $AssetRoot 'assets\data\title_database.json') -Force
        Copy-Item -LiteralPath (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') `
            -Destination (Join-Path $AssetRoot 'THIRD_PARTY_NOTICES.md') -Force
    }

    if (-not $SkipWindows) {
        $windowsBuild = Join-Path $projectRoot '.dart_tool\flutter_build\restricted-windows-release'
        Invoke-KernelCompile -TargetOs 'windows' -BuildDirectory $windowsBuild
        $windowsSnapshot = Join-Path $flutterRoot 'bin\cache\artifacts\engine\windows-x64-release\gen_snapshot.exe'
        & $windowsSnapshot --deterministic --snapshot_kind=app-aot-elf `
            "--elf=$(Join-Path $windowsBuild 'app.so')" --strip (Join-Path $windowsBuild 'app.dill')
        if ($LASTEXITCODE -ne 0) { throw 'Windows AOT snapshot failed' }

        $generatedConfig = Join-Path $projectRoot 'windows\flutter\ephemeral\generated_config.cmake'
        if (-not (Test-Path -LiteralPath $generatedConfig)) {
            throw 'Windows Flutter ephemeral files are missing. Run one normal Flutter Windows build first.'
        }
        $config = Get-Content -LiteralPath $generatedConfig -Raw
        $config = $config -replace 'set\(FLUTTER_VERSION "[^"]+" PARENT_SCOPE\)', "set(FLUTTER_VERSION `"$releaseVersion+$buildNumber`" PARENT_SCOPE)"
        $config = $config -replace 'set\(FLUTTER_VERSION_MAJOR \d+ PARENT_SCOPE\)', "set(FLUTTER_VERSION_MAJOR $($versionParts[0]) PARENT_SCOPE)"
        $config = $config -replace 'set\(FLUTTER_VERSION_MINOR \d+ PARENT_SCOPE\)', "set(FLUTTER_VERSION_MINOR $($versionParts[1]) PARENT_SCOPE)"
        $config = $config -replace 'set\(FLUTTER_VERSION_PATCH \d+ PARENT_SCOPE\)', "set(FLUTTER_VERSION_PATCH $($versionParts[2]) PARENT_SCOPE)"
        $config = $config -replace 'set\(FLUTTER_VERSION_BUILD \d+ PARENT_SCOPE\)', "set(FLUTTER_VERSION_BUILD $buildNumber PARENT_SCOPE)"
        Set-Content -LiteralPath $generatedConfig -Value $config -Encoding utf8

        $cmake = 'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        $msbuild = 'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\amd64\MSBuild.exe'
        & $cmake -S (Join-Path $projectRoot 'windows') -B (Join-Path $projectRoot 'build\windows\x64') -A x64 -DFLUTTER_TARGET_PLATFORM=windows-x64
        if ($LASTEXITCODE -ne 0) { throw 'Windows CMake generation failed' }
        & $msbuild (Join-Path $projectRoot 'build\windows\x64\runner\cia_bridge.vcxproj') /t:Build /p:Configuration=Release /p:Platform=x64 /p:BuildProjectReferences=false /m:1 /v:minimal
        if ($LASTEXITCODE -ne 0) { throw 'Windows runner build failed' }

        $windowsOutput = Join-Path $projectRoot 'build\windows\x64\runner\Release'
        Copy-Item -LiteralPath (Join-Path $windowsBuild 'app.so') -Destination (Join-Path $windowsOutput 'data\app.so') -Force
        Copy-FlutterAssets -AssetRoot (Join-Path $windowsOutput 'data\flutter_assets')
    }

    if (-not $SkipAndroid) {
        if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = 'F:\work\music_online_apk\.toolchains\android-sdk' }
        $jdk17 = if ($env:CIA_BRIDGE_JAVA_HOME) {
            $env:CIA_BRIDGE_JAVA_HOME
        } else {
            'F:\work\music_online_apk\.toolchains\jdk17'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $jdk17 'bin\java.exe'))) {
            throw "JDK 17 was not found: $jdk17. Set CIA_BRIDGE_JAVA_HOME to a JDK 17+ directory."
        }
        # Do not inherit a system-wide Java 8 JAVA_HOME: Gradle 9 requires 17+.
        $env:JAVA_HOME = $jdk17
        $env:Path = "$(Join-Path $env:JAVA_HOME 'bin');$env:Path"
        $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
        $env:ANDROID_USER_HOME = Join-Path $projectRoot '.toolchains\android-home'
        New-Item -ItemType Directory -Path $env:ANDROID_USER_HOME -Force | Out-Null

        $localProperties = Join-Path $projectRoot 'android\local.properties'
        $properties = Get-Content -LiteralPath $localProperties -Raw
        $properties = $properties -replace '(?m)^flutter\.versionName=.*$', "flutter.versionName=$releaseVersion"
        $properties = $properties -replace '(?m)^flutter\.versionCode=.*$', "flutter.versionCode=$buildNumber"
        Set-Content -LiteralPath $localProperties -Value $properties -Encoding utf8

        $androidBuild = Join-Path $projectRoot '.dart_tool\flutter_build\restricted-android-release'
        Invoke-KernelCompile -TargetOs 'android' -BuildDirectory $androidBuild
        $abis = @(
            @{ Name = 'armeabi-v7a'; Engine = 'android-arm-release'; Extra = @('--no-sim-use-hardfp', '--no-use-integer-division') },
            @{ Name = 'arm64-v8a'; Engine = 'android-arm64-release'; Extra = @() },
            @{ Name = 'x86_64'; Engine = 'android-x64-release'; Extra = @() }
        )
        foreach ($abi in $abis) {
            $abiOutput = Join-Path $androidBuild $abi.Name
            New-Item -ItemType Directory -Path $abiOutput -Force | Out-Null
            $snapshotter = Join-Path $flutterRoot "bin\cache\artifacts\engine\$($abi.Engine)\windows-x64\gen_snapshot.exe"
            $snapshotArgs = @('--deterministic', '--snapshot_kind=app-aot-elf', "--elf=$(Join-Path $abiOutput 'app.so')") + $abi.Extra + @((Join-Path $androidBuild 'app.dill'))
            & $snapshotter @snapshotArgs
            if ($LASTEXITCODE -ne 0) { throw "Android $($abi.Name) AOT snapshot failed" }
            Copy-Item -LiteralPath (Join-Path $abiOutput 'app.so') `
                -Destination (Join-Path $projectRoot "build\app\intermediates\flutter\release\$($abi.Name)\app.so") -Force
        }
        Copy-FlutterAssets -AssetRoot (Join-Path $projectRoot 'build\app\intermediates\flutter\release\flutter_assets')

        $gradleExcludes = @(
            '-x', 'compileFlutterBuildRelease',
            '-x', 'configureCMakeRelease',
            '-x', 'configureCMakeRelease[arm64-v8a]',
            '-x', 'configureCMakeRelease[armeabi-v7a]',
            '-x', 'configureCMakeRelease[x86_64]',
            '-x', 'buildCMakeRelease',
            '-x', 'buildCMakeRelease[arm64-v8a]',
            '-x', 'buildCMakeRelease[armeabi-v7a]',
            '-x', 'buildCMakeRelease[x86_64]',
            '-x', 'externalNativeBuildRelease'
        )
        Push-Location (Join-Path $projectRoot 'android')
        try {
            & .\gradlew.bat :app:assembleRelease @gradleExcludes --offline --no-daemon
            if ($LASTEXITCODE -ne 0) { throw 'Android Gradle packaging failed' }
        }
        finally {
            Pop-Location
        }
    }

    $distRoot = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
    if (-not $SkipWindows) {
        $windowsTarget = Join-Path $distRoot "windows\CIA-Bridge-v$releaseVersion-Windows-x64"
        $windowsArchive = Join-Path $distRoot "CIA-Bridge-v$releaseVersion-Windows-x64.zip"
        if (Test-Path -LiteralPath $windowsTarget) { Remove-Item -LiteralPath $windowsTarget -Recurse -Force }
        if (Test-Path -LiteralPath $windowsArchive) { Remove-Item -LiteralPath $windowsArchive -Force }
        New-Item -ItemType Directory -Path $windowsTarget -Force | Out-Null
        Copy-Item -Path (Join-Path $projectRoot 'build\windows\x64\runner\Release\*') -Destination $windowsTarget -Recurse -Force
        Compress-Archive -Path (Join-Path $windowsTarget '*') -DestinationPath $windowsArchive -CompressionLevel Optimal
    }
    if (-not $SkipAndroid) {
        $androidTarget = Join-Path $distRoot 'android'
        New-Item -ItemType Directory -Path $androidTarget -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk') `
            -Destination (Join-Path $androidTarget "CIA-Bridge-v$releaseVersion-Android-local-test.apk") -Force
    }

    Write-Host "Artifacts: $distRoot"
}
finally {
    Pop-Location
}
