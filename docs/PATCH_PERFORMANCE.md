# LayeredFS patch performance design

## Measured baseline

The original Corpse Party benchmark measured only its 127 `romfs` files and
18,108,898 raw bytes. The source archive actually contains 128 title files and
18,108,924 bytes: the previous sender silently omitted a 26-byte `code.ips`.
The timing table below remains a valid RomFS performance baseline, but not a
complete-patch correctness result. Two instrumented runs on the reference New
Nintendo 3DS isolate different costs:

| Run | Total | Compare | Setup | Write | Calls | Result |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| All 127 files changed | 298.3 s | 0.0 s | 63.6 s | 232.9 s | 161 | 17.27 MiB written |
| Aligned/pipelined changed run | 209.1 s | 0.0 s | 63.4 s | 139.5 s | 161 | 17.27 MiB written |
| All 127 files identical | 26.5 s | 2.6 s | 4.1 s | 0.0 s | 0 | 17.27 MiB writes skipped |

The aligned/pipelined run reduced write time by 40.1% and total time by 29.9%.
Its setup time nevertheless repeated at almost exactly 63.5 seconds. Comparing
it with the identical run isolated the remaining cost: every changed record
performed a post-write `FSFILE_GetSize`, while skipped records did not. On the
reference card those 127 redundant queries cost about 0.5 seconds each. The
receiver now trusts the already checked `FSFILE_Write` byte counts, total byte
count, and CRC32, and issues a size operation only when an older longer file
actually needs its tail truncated.

The identical run proves that the write skip is effective, but after
subtracting compare/setup/close it still spends roughly 19.7 seconds
transferring a payload that the receiver no longer needs. The two costs require
separate fixes.

An earlier 128 KiB run spent 235.1 seconds in writes. Increasing the receive
block to 512 KiB reduced the call count but did not reduce write time. The
bottleneck is therefore not HTTP requests or the number of FS IPC calls; it is
the ordinary SD/FAT path doing allocation and writes for many small files.

## Why local CIA installation can exceed 2 MiB/s

FBI local CIA installation is not the correct ordinary-file baseline. It calls
`AM_StartCiaInstall`, which returns a dedicated CIA import handle, and streams
the CIA into that handle. libctru describes it as a handle to which CIA data is
written; related AM entry points explicitly call it a virtual import file
handle. It cannot be redirected to arbitrary
`/luma/titles/<Title ID>/romfs` paths.

FBI's local CIA copy loop uses only a 256 KiB buffer and a single worker. Its
speed therefore does not come from a larger buffer or hidden multithreaded
copy API. It comes from AM importing a small number of large sequential title
contents instead of creating and extending 127 ordinary FAT files. FBI's
normal file paste path is the relevant comparison: it also uses
`FSFILE_Write(..., flags = 0)` on ordinary archive files.

References:

- [FBI CIA install implementation](https://github.com/Steveice10/FBI/blob/master/source/fbi/action/installcias.c)
- [FBI ordinary file paste implementation](https://github.com/Steveice10/FBI/blob/master/source/fbi/action/pastecontents.c)
- [libctru AM API](https://github.com/devkitPro/libctru/blob/master/libctru/include/3ds/services/am.h)

## Industry patterns and project mapping

GNU tar represents many file entries as one sequential archive that can be
sent through a pipe or network. CBPATCH1 already applies this pattern: one
logical byte stream carries every sorted path, record header, and payload. FBI
uses one 72-byte header range plus, only on a miss, one range for the remaining
stream. It therefore avoids per-file TCP and HTTP round trips.

Rsync exchanges a sorted file list, skips files that already match, pipelines
generator/sender/receiver work, and verifies reconstructed content. Syncthing
maintains file and block hashes and requests only missing or outdated blocks.
The useful lesson for CIA Bridge is not to add more connections; it is to avoid
performing destination work for content that is already present.

References:

- [The rsync algorithm](https://rsync.samba.org/tech_report/)
- [How rsync works](https://rsync.samba.org/how-rsync-works.html)
- [Syncthing Block Exchange Protocol](https://docs.syncthing.net/specs/bep-v1.html)
- [GNU tar basic format](https://www.gnu.org/software/tar/manual/html_node/Standard.html)
- [libctru filesystem API](https://github.com/devkitPro/libctru/blob/master/libctru/include/3ds/services/fs.h)
- [Luma3DS LayeredFS implementation](https://github.com/LumaTeam/Luma3DS/blob/master/sysmodules/loader/source/patcher.c)

## Implemented fast path

The FBI receiver now has two levels of avoidance.

First, CIA Bridge derives a deterministic 128-bit content-set ID from the
sorted path, size, and CRC metadata. FBI requests only header bytes 0-71 with
HTTP Range. A matching, CRC-protected completion marker ends the operation
after those 72 bytes; no target file is opened or read. Holding X while
choosing Yes bypasses this cache for an explicit full verification.

On a miss, FBI flushes an empty marker before changing any target. This makes
the marker a transaction boundary: cancellation or power loss cannot leave an
old bundle marked complete after partial changes. Only after every incoming
file passes size and CRC checks is the new marker written with a forced flush.
Failure to save the marker does not undo a successful installation; it simply
forces full verification next time.

Second, a cache miss or forced verification performs the following steps for
each sorted record:

1. Open or create the final file once with read/write access.
2. Read its current size.
3. When the size matches, calculate its CRC32 using one reusable aligned buffer.
4. If size and CRC32 match the incoming record, consume and verify the network
   payload without issuing any SD write.
5. Otherwise write sequentially and let the file grow, avoiding a separate
   whole-file preallocation pass.
6. After the complete incoming file passes CRC32, truncate an old longer tail
   only when the size recorded at open proves that it is necessary. Exact write
   return counts, accumulated length, and CRC32 avoid a redundant final size
   query for the common case.

This is deliberately a whole-file quick check, not rolling block delta. The
median file in the measured patch is small enough that block-level indexing
would add protocol state and 3DS CPU work before it saves useful data.

The first-install path uses page-aligned 512 KiB receive buffers and a separate
aligned write staging buffer, because record/path prefixes otherwise make the
actual payload pointer unaligned inside an aligned queue slot. The queue
remains bounded at four slots (2 MiB maximum). On New Nintendo 3DS, networking
stays on core 2 while the writer uses core 1 at the same priority as FBI's
local CIA data worker. FS session, archive, and file priorities are raised for
the operation; the previous session priority is restored afterwards.

Progress uses cumulative averages rather than 500 ms samples, because a single
large write followed by a run of tiny files made short-window speeds misleading.
The completion report includes comparison/setup/write/close time, actual write
calls, skipped bytes, cluster size, SD high-speed/clock state, and whether the
completion marker was saved. A cache hit has a compact dedicated report so the
small bottom screen does not wrap or clip diagnostic lines.

## Streaming compression instead of staging a ZIP

Staging a ZIP would make the network phase look fast, but Luma3DS still requires
real files under `/luma/titles/<Title ID>`. The receiver would then perform a
temporary ZIP write, read it back, inflate it, and finally perform the same
destination-file writes. It would also remove the overlap between network
reception and installation.

The implemented path instead negotiates per-record zlib compression. The sender
compresses each file independently and keeps codec `1` only when it saves at
least 32 bytes. FBI inflates directly into its reusable bounded write buffer,
calculates CRC32 over the uncompressed bytes, and writes the final destination
without a temporary archive.

The real AFM final patch contains 97 title files and 38,125,562 raw bytes,
including the 5,130-byte `code.ips`. The current builder produced 20,029,244
stored payload bytes and a 20,034,166-byte complete CBPATCH1 bundle, a 47.5%
payload reduction. All 97 records selected zlib in that build. This reduces the
wire phase; it does not remove the final SD/FAT writes, so hardware acceptance
must still measure the CPU/network tradeoff on a console.

## 3dsDL source review and decision

The 3dsDL review used commit `68d7a8032491c09ced53ecb5b8977b5374235318`.
Its ZIP path is carefully engineered: entries are sorted by their physical
local-header offsets, one 256 KiB reader and one 256 KiB inflate buffer are
reused, raw DEFLATE is streamed, directories are cached, and files larger than
the writer's 256 KiB piece are sized once before writing. These are valid FAT
and archive optimizations.

Most of those advantages already exist in the CIA Bridge path: records are
sorted and sequential, there is one bounded stream, parent directories are
reused across adjacent paths, and writes use a reusable aligned buffer. 3dsDL's
advertised four-connection design accelerates downloads; it is not evidence of
a faster 127-file FAT write path. Its public documentation does not publish a
ZIP extraction benchmark.

Two parts are deliberately not migrated:

- Staging a ZIP adds a temporary SD write and read before the same final-file
  writes, so it cannot remove the measured bottleneck.
- Preallocating every destination was already approximated by the earlier
  receiver. The reference card paid about 63 seconds in setup while write time
  remained about 233 seconds, so it moved allocation cost rather than removing
  it.

Per-record DEFLATE is now included as negotiated codec `1`. It does not reduce
the dominant destination-file allocation/write time, but it avoids staging a
ZIP and substantially reduces the AFM wire payload. Legacy receivers continue
to receive codec `0`; a sender refuses a legacy transfer that would otherwise
omit a title-root file such as `code.ips`.

3dsDL is GPLv3. This review uses performance concepts and measurements only;
no 3dsDL implementation code is copied into the FBI-derived project.

## Next protocol stage

The long-term CBPATCH2 design is manifest-first:

1. A fixed header points to a sorted manifest containing path, raw/stored size,
   CRC, codec, and payload offset.
2. FBI downloads only the manifest with HTTP Range.
3. It compares the manifest with a power-loss-safe A/B local index.
4. It combines adjacent required payload ranges and downloads only changed
   records.
5. The inactive index slot is committed only after all records verify.

This retains one sequential stream for changed data while removing both SD
writes and network payload for unchanged files. CBPATCH1 remains the compatible
fallback.

## Hardware acceptance gates

- Run the same real patch at least three times: first install, deterministic
  cache hit, and X+A forced verification.
- Record total, compare, setup, write, close, call count, written MiB, and saved
  MiB.
- The cache hit must report exactly the header-only path and zero target-file
  reads/writes. For the corrected Corpse Party bundle, forced verification must
  report 128 skipped files and zero write calls when all files still match.
- Compare 128/256/512 KiB blocks only on first-install data; select by median of
  interleaved runs rather than a single run.
- Compare one ordinary 17 MiB SD file against the 128-file tree before
  attributing any remaining difference to the physical card or AM importer.
- Cancellation, truncated payload, CRC mismatch, empty files, larger/smaller
  replacements, and power-loss resend must retain current safety semantics.
