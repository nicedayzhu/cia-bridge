# CIA Bridge contributor instructions

CIA Bridge is a Flutter sender for the receiver in `../FBI-cia-bridge`.
Preserve unrelated and uncommitted work in both repositories.

## Build and validation

- `pubspec.yaml` is the single source of truth for the release version.
- In a normal terminal, run `scripts/build-all.ps1`. It resolves dependencies,
  analyzes the project, runs tests, builds Windows and Android, and packages
  artifacts under `dist/`.
- In a restricted Codex Windows sandbox, use `scripts/build-restricted.ps1`.
  It replaces child processes that the sandbox blocks while producing the
  same local test artifacts.
- Official Android releases require the four `CIA_BRIDGE_KEYSTORE_*` values.
  Without them, local builds are debug-signed and named `*-local-test.apk`.
- Before publishing, verify the Windows product version, APK `versionName`, APK
  signature, responsive layouts, and the main device/file/error/result flows.
- Keep `assets/fonts/NotoSansSC-CIABridge.ttf` synchronized with visible text.
  Missing glyphs are easiest to catch in the golden tests.

## Product behavior

- The flow remains: select a 3DS, then select files and send.
- Exact discovery advertises install port `5000` and patch port `5002`.
  Reachable candidates must remain visibly distinct from verified receivers.
- Installation files support push and QR. LayeredFS patches require an exact
  CIA Bridge receiver and push mode.
- Keep the 3DS menu path exact:
  `FBI / Remote Install / Receive URLs over the network`.
- Error states need a direct retry action. Installation transfers may also
  fall back to QR; patch transfers may not.

## Patch transport

Read `docs/PATCH_PROTOCOL.md` and `docs/PATCH_PERFORMANCE.md` before changing
patch transport.

- Do not stage a ZIP on the 3DS or reintroduce destination preallocation.
- Preserve deterministic bundle IDs and the 72-byte header-only cache hit.
- Keep sequential raw records, per-file CRC checks, bounded queues, skipped
  identical writes, and the no-redundant-size-query path.
- Hardware acceptance covers first install, cache hit, and forced verification;
  use the measurements and gates in `docs/PATCH_PERFORMANCE.md`.
