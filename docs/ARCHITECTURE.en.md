# Architecture

[简体中文](ARCHITECTURE.md)

## Data flow

```text
Windows path / Android content:// URI
                 │
                 ▼
       Temporary LAN HTTP server ─────────► FBI downloads and installs
                 ▲                           ▲
                 │ Local URL                 │
                 ├──── QR code ──────────────┤
                 │                           │
                 └──── FBI TCP/5000 push ────┘
```

## Layers

- `lib/ui`: responsive Material 3 interface, with desktop and narrow mobile layouts.
- `TransferController`: shared file selection, network settings, QR/push modes, progress, and error state.
- `CiaMetadataParser`: bounded, offline range parser for CIA headers, TMD fields, and optional SMDH text/icon data.
- `FbiProtocolClient`: pure Dart implementation of FBI's TCP URL push protocol.
- `DeviceDiscovery`: first broadcasts a versioned UDP request for an exact, ready FBI receiver; without a reply, warms the local `/24` neighbor cache, filters Nintendo OUIs, and accepts safe Android reachability candidates.
- `DesktopLanServer`: Dart `HttpServer` for direct streaming from Windows paths.
- `FileHostBridge`: narrow interface between Flutter and platform capabilities.
- Windows runner: C++ `IFileOpenDialog` multi-file picker and IP Helper neighbor-table access.
- Android adapter: Kotlin `ACTION_OPEN_DOCUMENT`, `ContentResolver` streaming, neighbor discovery, safe candidate scanning, and foreground service.

## Design decisions

- **Shared experience:** one Flutter codebase owns the visual system, cards, states, and transfer flow.
- **Progressive flow:** users choose a 3DS before entering the file and send stage; network and port controls stay in settings.
- **Non-destructive discovery:** exact receivers answer on UDP/5001; older FBI builds fall back to Nintendo OUI or safe candidate discovery. The app never connects to FBI TCP/5000 merely to probe a device.
- **Streaming:** Windows uses `File.openRead`; Android uses `ParcelFileDescriptor` and `InputStream`.
- **Offline metadata:** selection reads only the CIA header, a small TMD prefix, and the optional SMDH block. No title database or network lookup is required; parsing errors remain non-blocking.
- **Known length:** every response carries a fixed `Content-Length` for FBI compatibility.
- **Range support:** one bounded, open-ended, or suffix byte range is supported for retries and resume behavior.
- **Session paths:** each server session receives a random 96-bit token and UTF-8 percent-encoded filenames.
- **Port fallback:** if the preferred HTTP port is occupied, the server binds another available port and publishes the actual URL.
- **Lifecycle:** QR mode remains active until stopped; push mode waits for FBI's one-byte acknowledgement. Android uses a foreground service for long transfers.
- **No desktop JRE:** the Windows package contains the Flutter runtime and does not depend on system Java.

## Boundaries

- The project does not include a public download client, title catalog, or copyrighted software source.
- CIA metadata is limited to information embedded in the selected file. Files without SMDH still show TMD-level details when possible.
- Only the CIA Bridge FBI fork explicitly advertises its receive state. Stock and older builds can still be found by Nintendo OUI or as online candidates, but those fallbacks cannot prove FBI is waiting.
- Android document providers that cannot report file length are rejected to avoid sending an incorrect response size.
- QR capacity is limited; TCP URL push is recommended for many long URLs.
