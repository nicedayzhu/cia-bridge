# CBPATCH1 LayeredFS streaming protocol

CBPATCH1 is a little-endian, sequential container for sending a set of
LayeredFS `romfs` overlay files to FBI CIA Bridge. Paths are always UTF-8 and
relative to `romfs/`; the receiver never accepts an absolute destination from
the sender.

## Sender input normalization

CIA Bridge accepts either a directory tree or a ZIP archive. It locates one
real `luma/titles/<16-hex Title ID>/romfs` path, ignores files outside that
`romfs` tree, and converts only its files to CBPATCH1. An arbitrary outer
wrapper directory is allowed. `patch_manifest.json` is not required and is not
used to decide the Title ID or payload. ZIP entries are path-validated and
materialized one file at a time, so the complete uncompressed tree is never
held in memory.

The display name resolved from the Title ID is UI metadata only and is not part
of CBPATCH1. An offline catalog is consulted first; optional online enrichment
for an unknown ID never changes or blocks the wire payload.

CIA Bridge emits raw records only. ZIP decompression stays on the faster
Windows/Android sender, and the receiver copies payload bytes directly into
their final target paths without an inflate pass. CBPATCH1 was not publicly
released with a compressed record codec, so nonzero codec values are invalid
rather than a compatibility format.

## Header (72 bytes)

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | `char[8]` | `CBPATCH1` |
| 8 | `u32` | Header size (`72`) |
| 12 | `u32` | Flags (`0`) |
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
| 2 | `u8` | Codec: `0` raw (all other values are invalid) |
| 3 | `u8` | Flags (`0`) |
| 4 | `u64` | Uncompressed size |
| 12 | `u64` | Stored size |
| 20 | `u32` | CRC32 of the uncompressed file |

After the 24-byte record header come `path length` bytes and then `stored size`
bytes. Records are sorted by path. A receiver must reject `.`, `..`, empty path
segments, backslashes, absolute paths, unsupported codecs, size overflow, CRC
mismatch, extra/truncated records, and a header CRC mismatch.

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
index. A cache hit is accepted only when the target `romfs` directory already
exists. The receiver then completes after the 72-byte request without opening,
reading, or writing any target file.

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
choosing Yes whenever files under that title's `romfs` tree may have been
changed outside CIA Bridge.

## Target-file update semantics

The target is fixed to `sdmc:/luma/titles/<Title ID>/romfs`. Installation is an
incremental overlay: before each record, the receiver opens or creates its
matching final destination and compares its size and CRC32. On the complete
verification path, an identical file still has the incoming payload consumed
and verified but performs no SD write.

A changed file receives the raw payload from offset zero. New and shorter files
grow naturally through sequential `FSFILE_Write` calls instead of being
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
