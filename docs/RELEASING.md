# CI and release automation

[简体中文](#简体中文)

## Continuous integration

`.github/workflows/ci.yml` runs for every branch push, pull request to `main`,
and manual dispatch. The Windows job runs `flutter analyze`, all tests, and a
release build. The Android job builds a release APK with the local debug signing
fallback. CI artifacts are not published.

## One-time Android signing setup

Official APKs must use one persistent signing key so users can update without
uninstalling the previous version. From an authenticated development machine,
run:

```powershell
$env:JAVA_HOME = 'path\to\jdk17'
.\scripts\setup-android-signing.ps1
```

The script creates a key under the ignored `.secrets/` directory and uploads
these repository secrets:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Back up `.secrets/` securely. Losing this key means future APKs cannot update
existing installations. Never commit it.

The original v0.1.0 APK was signed with Flutter's development key. The first
APK produced by this workflow uses the new persistent release key, so v0.1.0
test installations must be uninstalled once before installing it. Later signed
releases can update in place normally.

## Publishing a release

1. Update `version:` in `pubspec.yaml`, for example `0.2.0+2`.
2. Commit and push the change; wait for CI to pass.
3. Tag the same commit and push the tag:

```powershell
git tag v0.2.0
git push origin v0.2.0
```

`.github/workflows/release.yml` rejects a tag whose semantic version does not
match `pubspec.yaml`. It then repeats analysis and tests, builds a signed Android
APK and Windows portable ZIP, generates `SHA256SUMS.txt`, and creates the GitHub
Release with generated notes. A failed build never publishes a release.

## 简体中文

普通分支 push、面向 `main` 的 Pull Request 和手动运行都会触发 CI：Windows
任务执行静态分析、全部测试与 release 构建，Android 任务验证 APK 构建。

正式 Android APK 必须使用固定签名。首次配置时，在已登录 GitHub CLI 且可用
JDK 17 的电脑上运行：

```powershell
$env:JAVA_HOME = 'JDK 17 路径'
.\scripts\setup-android-signing.ps1
```

脚本会把签名文件和凭据保存在已忽略的 `.secrets/`，并设置 GitHub Secrets。
请安全备份该目录且绝对不要提交；丢失签名后，新 APK 将无法覆盖旧版本。

最初发布的 v0.1.0 APK 使用 Flutter 开发签名。此工作流首次生成的正式签名
APK 与它的证书不同，因此已有 v0.1.0 测试安装需要先卸载一次；之后的正式
签名版本即可正常覆盖升级。

发布时先修改 `pubspec.yaml` 版本并让普通 CI 通过，再创建同版本标签，例如
`v0.2.0`。标签推送后，Release 工作流会再次验证、构建 Windows ZIP 和带固定
签名的 Android APK、生成 SHA-256 清单并自动创建 GitHub Release。任一构建
失败都不会发布。
