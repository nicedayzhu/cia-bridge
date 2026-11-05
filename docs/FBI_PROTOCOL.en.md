# FBI Remote Install protocol

[简体中文](FBI_PROTOCOL.md)

CIA Bridge implements both remote-install entry points exposed by FBI.

## QR-code entry point

The QR code contains an HTTP URL. Multiple files are represented as newline-separated URLs. CIA Bridge starts a temporary HTTP server on the phone or computer and FBI downloads from that device over the LAN. TCP push is recommended when many long URLs would make the QR code too dense.

## TCP URL push entry point

FBI's `Receive URLs over the network` mode listens on `TCP/5000` by default. The client sends:

```text
uint32  payload_size   network byte order (big-endian)
byte[]  payload        ASCII URLs separated by LF (0x0A)
```

After reading the URLs, FBI enters its confirmation and install flow. When processing finishes, it sends one acknowledgement byte and closes the connection. CIA Bridge waits for that byte before showing the confirmed state.

Filenames are encoded as UTF-8 and then percent-encoded in the URL path, keeping the complete URL ASCII-compatible.

References:

- <https://github.com/Steveice10/FBI/blob/master/source/fbi/remoteinstall.c>
- <https://github.com/Steveice10/FBI/blob/master/servefiles/servefiles.py>
