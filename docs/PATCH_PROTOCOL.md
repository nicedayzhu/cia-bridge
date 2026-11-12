# CBPATCH1 LayeredFS streaming protocol

CBPATCH1 is a little-endian, sequential container for sending a set of Luma3DS
title overlay files to FBI CIA Bridge. Paths are always UTF-8 and relative to
either the title root (current format) or its `romfs` directory (legacy
format); the receiver never accepts an absolute destination from the sender.

## Sender input normalization

CIA Bridge accepts either a directory tree or a ZIP archive. It locates one
real `luma/titles/<16-hex Title ID>` path and converts its files, including
siblings such as `code.ips` and the `romfs` tree, to CBPATCH1. An arbitrary
outer wrapper directory is allowed. `patch_manifest.json` is not required and
is not used to decide the Title ID or payload. ZIP entries are path-validated
and materialized one file at a time, so the complete uncompressed tree is
never held in memory.

The display name resolved from the Title ID is UI metadata only and is not part
of CBPATCH1. An offline catalog is consulted first; optional online enrichment
for an unknown ID never changes or blocks the wire payload.

CIA Bridge negotiates the `title-root` and `zlib` features through discovery.
With both current endpoints, each source file is compressed independently with
the zlib wrapper and codec `1` is selected only when it saves at least 32 bytes;
otherwise codec `0` carries the raw bytes. This keeps decompression bounded to
one record and never stages a ZIP on the SD card.

An older receiver advertises neither feature. The sender then emits legacy
raw records whose paths are relative to `romfs`. If the selected patch also
contains a title-root file such as `code.ips`, the sender rejects the transfer
with an upgrade error instead of silently producing an incomplete patch.

## Header (72 bytes)

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | `char[8]` | `CBPATCH1` |
| 8 | `u32` | Header size (`72`) |
| 12 | `u32` | Flags: bit 0 = paths relative to the title root |
| 16 | `u64` | Target Title ID |
| 24 | `u32` | File count |
| 28 | `u32` | Reserved (`0`) |
| 32 | `u64` | Total uncompressed bytes |
| 40 | `u64` | Total stored payload bytes |
| 48 | `u8[16]` | Deterministic content-set ID |
| 64 | `u32` | CRC32 of bytes 0-63 |
| 68 | `u32` | Reserved (`0`) |

The content-set ID is the first 16 bytes of SHA-256 over this canonical byte
stream:

1. ASCII `CBPATCH1-CONTENT-ID-V1` followed by one NUL byte.
2. File count as little-endian `u32`.
3. For every record in sorted path order: UTF-8 path length as little-endian
   `u16`, the path bytes, raw size as little-endian `u64`, and CRC32 as
   little-endian `u32`.

Source labels, source IDs, ZIP wrapper paths, temporary paths, timestamps, and
build time are not hashed. Rebuilding the same record set therefore produces
the same ID and lets a receiver recognize a previously completed bundle before
downloading its payload. The field remains an opaque 16-byte value to older FBI
receivers, so its layout and compatibility are unchanged. It is a cache key,
not an authentication mechanism.

## File records

Each record is immediately followed by its path and raw payload, so the 3DS
needs only a fixed-size input buffer.

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | `u16` | UTF-8 path length (1-1024) |
| 2 | `u8` | Codec: `0` raw, `1` zlib-wrapped DEFLATE |
| 3 | `u8` | Flags (`0`) |
| 4 | `u64` | Uncompressed size |
| 12 | `u64` | Stored size |
| 20 | `u32` | CRC32 of the uncompressed file |

After the 24-byte record header come `path length` bytes and then `stored size`
bytes. Records are sorted by path. A receiver must reject `.`, `..`, empty path
segments, backslashes, absolute paths, unsupported codecs, size overflow, CRC
mismatch, extra/truncated records, and a header CRC mismatch.

For codec `0`, stored size must equal uncompressed size. Codec `1` is decoded
incrementally and must reach `Z_STREAM_END` at exactly the declared stored and
uncompressed lengths. CRC32 is always calculated over the uncompressed bytes.
Unknown header flag bits are invalid.

The wire format permits paths up to 1024 bytes, but the current 3DS filesystem
implementation limits sender-created relative paths to 384 UTF-8 bytes so the
fixed target prefix and final path remain below FBI's 512-byte path buffer.

## HTTP delivery and completion cache

The current FBI CIA Bridge receiver uses two exact HTTP byte-range requests. It
first requests `bytes=0-71` with identity encoding and requires an HTTP `206`
response. Those 72 bytes are enough to validate the complete fixed header and
look up a completion marker before any payload is transferred.

The marker is stored at
`sdmc:/luma/titles/<Title ID>/.cia-bridge-cache`. It binds the marker format,
Title ID, deterministic content-set ID, and header CRC, and also carries its
own CRC. A valid marker is a whole-bundle completion assertion, not a per-file
index. A cache hit is accepted only when the target title directory already
exists for a title-root bundle, or the target `romfs` directory exists for a
legacy bundle. The receiver then completes after the 72-byte request without
opening, reading, or writing any target file.

On a cache miss, or when the user holds X while choosing Yes to force
verification, the receiver first invalidates and flushes the old marker. It
then requests `bytes=72-` and parses the remaining records as one sequential
stream. Only after every record passes its length and CRC checks and every
target file closes successfully does the receiver write and flush a new valid
marker. Cancellation, power loss, or a transfer/write error therefore leaves
the cache invalid, so resending the bundle takes the complete verification and
repair path. Failure to save the final marker does not turn an otherwise
successful install into a failed install; it only disables the next fast hit.

Because the marker describes the last completed bundle, it cannot detect a
target file that another program edits or deletes afterward. Hold X while
choosing Yes whenever files under that title may have been changed outside CIA
Bridge.

## Target-file update semantics

With header flag bit 0 set, the target base is
`sdmc:/luma/titles/<Title ID>`; for example, `code.ips` and
`romfs/script.bin` land at their normal Luma3DS locations. With flags `0`, the
legacy target base remains `sdmc:/luma/titles/<Title ID>/romfs`.
Installation is an incremental overlay: before each record, the receiver opens
or creates its matching final destination and compares its size and CRC32. On
the complete verification path, an identical file still has the incoming
payload consumed, decompressed when needed, and verified but performs no SD
write. The title-root cache filename `.cia-bridge-cache` is reserved and cannot
be supplied as a record.

A changed file receives the uncompressed payload from offset zero. New and
shorter files grow naturally through sequential `FSFILE_Write` calls instead of being
preallocated with a separate resize pass. If an old file has a longer tail, the
receiver truncates it only after the complete incoming payload passes its CRC32
check. Exact write return counts, accumulated length, and CRC32 already verify
the common case, so the receiver does not repeat a final size query. This
avoids delete/create directory-entry churn, write-before-data preallocation,
and redundant writes on repeat installs.

Existing files not represented by a record are preserved. No staging tree or
rollback copy is created. Cancelling keeps completed replacements, but the file
being written may be incomplete; the already-invalidated marker guarantees
that sending the same bundle again takes the full path and repairs it.
