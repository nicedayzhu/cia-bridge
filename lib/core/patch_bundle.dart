import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import 'models.dart';

const patchBundleMagic = 'CBPATCH1';
const patchBundleHeaderSize = 72;
const patchBundleRecordHeaderSize = 24;
const patchBundleMaxPathBytes = 1024;
const patchReceiverMaxRelativePathBytes = 384;
const _patchBundleContentIdDomain = 'CBPATCH1-CONTENT-ID-V1\u0000';

enum PatchCodec { raw }

class PatchInput {
  const PatchInput.local(
    this.localPath, {
    required this.label,
    this.deleteLocalPath = false,
  }) : titleId = null,
       files = const [];

  const PatchInput.streamed({
    required this.titleId,
    required this.files,
    required this.label,
  }) : localPath = null,
       deleteLocalPath = false;

  final String? localPath;
  final String? titleId;
  final List<PatchInputFile> files;
  final String label;
  final bool deleteLocalPath;

  Future<void> dispose() async {
    final path = localPath;
    if (!deleteLocalPath || path == null) return;
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) await File(path).delete();
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    }
  }
}

class PatchInputFile {
  const PatchInputFile({
    required this.id,
    required this.relativePath,
    required this.size,
    required this.openRead,
    this.expectedCrc32,
  });

  final String id;
  final String relativePath;
  final int size;
  final Stream<List<int>> Function() openRead;
  final int? expectedCrc32;
}

class PreparedPatch {
  const PreparedPatch({
    required this.file,
    required this.titleId,
    required this.bundleId,
    required this.fileCount,
    required this.rawBytes,
    required this.storedBytes,
    required this.romfsPath,
    required this.sourceLabel,
    required this.temporaryDirectory,
  });

  final ShareFile file;
  final String titleId;
  final String bundleId;
  final int fileCount;
  final int rawBytes;
  final int storedBytes;
  final String romfsPath;
  final String sourceLabel;
  final String temporaryDirectory;

  Future<void> delete() async {
    final directory = Directory(temporaryDirectory);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

typedef PatchBuildProgress = void Function(
  int completedFiles,
  int totalFiles,
  String relativePath,
);

class PatchBundleBuilder {
  const PatchBundleBuilder();

  Future<PreparedPatch> build(
    String selectedPath, {
    PatchBuildProgress? onProgress,
  }) => buildInput(
    PatchInput.local(selectedPath, label: _basename(selectedPath)),
    onProgress: onProgress,
  );

  Future<PreparedPatch> buildInput(
    PatchInput input, {
    PatchBuildProgress? onProgress,
  }) async {
    _PatchSource? source;
    try {
      if (input.localPath != null) {
        source = await _openLocalSource(input);
      } else {
        final titleId = input.titleId?.toUpperCase();
        if (titleId == null || !_isTitleId(titleId)) {
          throw const FormatException('补丁来源没有有效的 16 位 Title ID');
        }
        source = _PatchSource(
          titleId: titleId,
          label: input.label,
          romfsPath: input.label,
          files: input.files
              .map(
                (file) => _PatchFile(
                  relativePath: file.relativePath,
                  size: file.size,
                  openRead: file.openRead,
                  expectedCrc32: file.expectedCrc32,
                ),
              )
              .toList(growable: false),
        );
      }
      _validateFiles(source.files);
      return await _buildSource(source, onProgress: onProgress);
    } finally {
      await source?.close();
    }
  }

  Future<_PatchSource> _openLocalSource(PatchInput input) async {
    final path = input.localPath!;
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      return _openDirectorySource(Directory(path), input.label);
    }
    if (type == FileSystemEntityType.file &&
        path.toLowerCase().endsWith('.zip')) {
      return _openZipSource(File(path), input.label);
    }
    if (type == FileSystemEntityType.link) {
      throw FileSystemException('补丁来源不能是符号链接', path);
    }
    throw FileSystemException('请选择 LayeredFS 补丁目录或 ZIP 文件', path);
  }

  Future<_PatchSource> _openDirectorySource(
    Directory selected,
    String label,
  ) async {
    final target = await _locateRomfs(selected);
    final files = await _collectDirectoryFiles(target.romfs);
    return _PatchSource(
      titleId: target.titleId,
      label: label,
      romfsPath: target.romfs.path,
      files: files,
    );
  }

  Future<_PatchSource> _openZipSource(File zipFile, String label) async {
    final input = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeStream(
        input,
        verify: true,
        throwOnError: true,
      );
      final targets = <String, List<_PatchFile>>{};
      final roots = <String>{};
      for (final entry in archive.files) {
        final match = _matchArchivePath(entry.name);
        if (match == null) continue;
        if (entry.isSymbolicLink) {
          throw FormatException('ZIP 补丁不能包含符号链接：${entry.name}');
        }
        roots.add(match.rootKey);
        if (!entry.isFile || match.relativePath.isEmpty) continue;
        _validateRelativePath(match.relativePath);
        final files = targets.putIfAbsent(match.titleId, () => []);
        files.add(
          _PatchFile(
            relativePath: match.relativePath,
            size: entry.size,
            expectedCrc32: entry.crc32,
            materialize: (target) async {
              final output = OutputFileStream(target.path);
              try {
                entry.writeContent(output, freeMemory: true);
              } finally {
                await output.close();
              }
            },
          ),
        );
      }
      if (targets.isEmpty) {
        throw const FormatException(
          'ZIP 中没有找到 luma/titles/<Title ID>/romfs 补丁目录',
        );
      }
      if (targets.length > 1) {
        final ids = targets.keys.toList()..sort();
        throw FormatException(
          'ZIP 包含多个 Title ID：${ids.join(', ')}。请一次只发送一个游戏。',
        );
      }
      if (roots.length > 1) {
        throw const FormatException('ZIP 包含多个 LayeredFS romfs 根目录。请一次只选择一个补丁。');
      }
      final titleId = targets.keys.single;
      return _PatchSource(
        titleId: titleId,
        label: label.replaceFirst(RegExp(r'\.zip$', caseSensitive: false), ''),
        romfsPath: '${zipFile.path}!/luma/titles/$titleId/romfs',
        files: targets[titleId]!,
        onClose: input.close,
      );
    } catch (_) {
      await input.close();
      rethrow;
    }
  }

  Future<PreparedPatch> _buildSource(
    _PatchSource source, {
    PatchBuildProgress? onProgress,
  }) async {
    final files = source.files;
    if (files.isEmpty) {
      throw const FormatException('补丁的 romfs 目录中没有文件');
    }
    final totalRaw = files.fold<int>(0, (sum, entry) => sum + entry.size);
    final temporary = await Directory.systemTemp.createTemp(
      'cia_bridge_patch_',
    );
    final stagedBundleFile = File(
      '${temporary.path}${Platform.pathSeparator}'
      'payload.cbpatch.tmp',
    );
    final sourceScratch = File(
      '${temporary.path}${Platform.pathSeparator}payload.raw.tmp',
    );

    RandomAccessFile? output;
    try {
      output = await stagedBundleFile.open(mode: FileMode.write);
      await output.writeFrom(Uint8List(patchBundleHeaderSize));

      // The ID deliberately covers only stable record metadata. Source labels,
      // temporary paths, timestamps and archive layout therefore cannot change
      // it. Length-prefixing every UTF-8 path keeps the canonical stream
      // unambiguous, and the files have already been sorted by path.
      late Digest contentDigest;
      final contentHash = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((digests) {
          contentDigest = digests.single;
        }),
      );
      contentHash.add(ascii.encode(_patchBundleContentIdDomain));
      final contentFileCount = ByteData(4)
        ..setUint32(0, files.length, Endian.little);
      contentHash.add(contentFileCount.buffer.asUint8List());

      var totalStored = 0;
      for (var index = 0; index < files.length; index++) {
        final entry = files[index];
        final sourceFile = await _materializeIfNeeded(entry, sourceScratch);
        final actualSize = await sourceFile.length();
        if (actualSize != entry.size) {
          throw FormatException(
            '补丁文件大小不匹配：${entry.relativePath} '
            '(${entry.size} != $actualSize)',
          );
        }

        final pathBytes = utf8.encode(entry.relativePath);
        final recordOffset = await output.position();
        await output.writeFrom(Uint8List(patchBundleRecordHeaderSize));
        await output.writeFrom(pathBytes);

        // Fast-install path: ZIP decompression stays on the phone/PC and the
        // 3DS receives raw records that can be written directly to SD. Reserve
        // the record header and back-fill its CRC so the source is copied and
        // hashed in one pass.
        final crc = Crc32();
        var payloadSize = 0;
        await for (final chunk in sourceFile.openRead()) {
          crc.add(chunk);
          payloadSize += chunk.length;
          await output.writeFrom(chunk);
        }
        if (payloadSize != entry.size) {
          throw FormatException(
            'Patch file size changed while reading: ${entry.relativePath} '
            '(${entry.size} != $payloadSize)',
          );
        }
        if (entry.expectedCrc32 != null && crc.value != entry.expectedCrc32) {
          throw FormatException('ZIP 文件 CRC 校验失败：${entry.relativePath}');
        }

        final contentPathLength = ByteData(2)
          ..setUint16(0, pathBytes.length, Endian.little);
        final contentRecord = ByteData(12)
          ..setUint64(0, entry.size, Endian.little)
          ..setUint32(8, crc.value, Endian.little);
        contentHash
          ..add(contentPathLength.buffer.asUint8List())
          ..add(pathBytes)
          ..add(contentRecord.buffer.asUint8List());

        final record = ByteData(patchBundleRecordHeaderSize)
          ..setUint16(0, pathBytes.length, Endian.little)
          ..setUint8(2, PatchCodec.raw.index)
          ..setUint8(3, 0)
          ..setUint64(4, entry.size, Endian.little)
          ..setUint64(12, payloadSize, Endian.little)
          ..setUint32(20, crc.value, Endian.little);
        final endOffset = await output.position();
        await output.setPosition(recordOffset);
        await output.writeFrom(record.buffer.asUint8List());
        await output.setPosition(endOffset);
        totalStored += payloadSize;
        if (sourceFile.path == sourceScratch.path &&
            await sourceScratch.exists()) {
          await sourceScratch.delete();
        }
        onProgress?.call(index + 1, files.length, entry.relativePath);
      }

      contentHash.close();
      final bundleIdBytes = Uint8List.fromList(
        contentDigest.bytes.sublist(0, 16),
      );
      final bundleId = _hex(bundleIdBytes);

      final header = ByteData(patchBundleHeaderSize);
      header.buffer.asUint8List().setAll(0, ascii.encode(patchBundleMagic));
      header
        ..setUint32(8, patchBundleHeaderSize, Endian.little)
        ..setUint32(12, 0, Endian.little)
        ..setUint64(16, int.parse(source.titleId, radix: 16), Endian.little)
        ..setUint32(24, files.length, Endian.little)
        ..setUint32(28, 0, Endian.little)
        ..setUint64(32, totalRaw, Endian.little)
        ..setUint64(40, totalStored, Endian.little);
      header.buffer.asUint8List().setAll(48, bundleIdBytes);
      final headerCrc = Crc32()..add(header.buffer.asUint8List(0, 64));
      header
        ..setUint32(64, headerCrc.value, Endian.little)
        ..setUint32(68, 0, Endian.little);
      await output.setPosition(0);
      await output.writeFrom(header.buffer.asUint8List());
      await output.flush();
      await output.close();
      output = null;
      if (await sourceScratch.exists()) await sourceScratch.delete();

      final bundleFile = await stagedBundleFile.rename(
        '${temporary.path}${Platform.pathSeparator}'
        '${source.titleId}-$bundleId.cbpatch',
      );

      final bundleSize = await bundleFile.length();
      return PreparedPatch(
        file: ShareFile(
          id: bundleFile.path,
          name: '${source.titleId}.cbpatch',
          size: bundleSize,
          path: bundleFile.path,
        ),
        titleId: source.titleId,
        bundleId: bundleId,
        fileCount: files.length,
        rawBytes: totalRaw,
        storedBytes: totalStored,
        romfsPath: source.romfsPath,
        sourceLabel: source.label,
        temporaryDirectory: temporary.path,
      );
    } catch (_) {
      await output?.close();
      if (await temporary.exists()) await temporary.delete(recursive: true);
      rethrow;
    }
  }

  Future<File> _materializeIfNeeded(_PatchFile entry, File scratch) async {
    if (entry.localFile != null) return entry.localFile!;
    if (await scratch.exists()) await scratch.delete();
    if (entry.materialize != null) {
      await entry.materialize!(scratch);
      return scratch;
    }
    final stream = entry.openRead?.call();
    if (stream == null) {
      throw StateError('补丁文件没有可读来源：${entry.relativePath}');
    }
    await stream.pipe(scratch.openWrite(mode: FileMode.write));
    return scratch;
  }

  Future<_PatchTarget> _locateRomfs(Directory selected) async {
    final direct = await _targetFromRomfs(selected);
    if (direct != null) return direct;

    final candidates = <_PatchTarget>[];
    await for (final entity in selected.list(
      recursive: true,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw FileSystemException('补丁目录不能包含符号链接', entity.path);
      }
      if (type != FileSystemEntityType.directory ||
          _basename(entity.path).toLowerCase() != 'romfs') {
        continue;
      }
      final target = await _standardTargetFromRomfs(Directory(entity.path));
      if (target != null) candidates.add(target);
    }
    if (candidates.isEmpty) {
      throw const FormatException('没有找到 luma/titles/<Title ID>/romfs 补丁目录');
    }
    if (candidates.length > 1) {
      final ids =
          candidates.map((candidate) => candidate.titleId).toSet().toList()
            ..sort();
      throw FormatException(
        '补丁目录包含多个 LayeredFS romfs 根目录'
        '（${ids.join(', ')}）。请一次只选择一个补丁。',
      );
    }
    return candidates.single;
  }

  Future<_PatchTarget?> _targetFromRomfs(Directory directory) async {
    final name = _basename(directory.path).toLowerCase();
    if (name == 'romfs' && await directory.exists()) {
      final titleId = _basename(directory.parent.path).toUpperCase();
      if (_isTitleId(titleId)) {
        return _PatchTarget(titleId, directory.absolute);
      }
    }

    final selectedName = _basename(directory.path);
    if (_isTitleId(selectedName)) {
      final romfs = Directory(_join(directory.path, 'romfs'));
      if (await romfs.exists()) {
        return _PatchTarget(selectedName.toUpperCase(), romfs.absolute);
      }
    }
    return null;
  }

  Future<_PatchTarget?> _standardTargetFromRomfs(Directory romfs) async {
    if (_basename(romfs.path).toLowerCase() != 'romfs' ||
        !await romfs.exists()) {
      return null;
    }
    final title = romfs.parent;
    final titleId = _basename(title.path).toUpperCase();
    if (!_isTitleId(titleId) ||
        _basename(title.parent.path).toLowerCase() != 'titles' ||
        _basename(title.parent.parent.path).toLowerCase() != 'luma') {
      return null;
    }
    return _PatchTarget(titleId, romfs.absolute);
  }

  Future<List<_PatchFile>> _collectDirectoryFiles(Directory romfs) async {
    final root = romfs.absolute.path;
    final files = <_PatchFile>[];
    await for (final entity in romfs.list(
      recursive: true,
      followLinks: false,
    )) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw FileSystemException('补丁目录不能包含符号链接', entity.path);
      }
      if (type != FileSystemEntityType.file) continue;
      final file = File(entity.path);
      final relative = entity.absolute.path
          .substring(root.length + 1)
          .replaceAll('\\', '/');
      files.add(
        _PatchFile(
          relativePath: relative,
          size: await file.length(),
          localFile: file,
        ),
      );
    }
    return files;
  }

  _ArchivePathMatch? _matchArchivePath(String rawPath) {
    final normalized = rawPath.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
      throw FormatException('ZIP 包含绝对路径：$rawPath');
    }
    final segments = normalized
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.any((part) => part == '.' || part == '..')) {
      throw FormatException('ZIP 包含不安全路径：$rawPath');
    }
    for (var index = 0; index + 3 < segments.length; index++) {
      if (segments[index].toLowerCase() != 'luma' ||
          segments[index + 1].toLowerCase() != 'titles' ||
          !_isTitleId(segments[index + 2]) ||
          segments[index + 3].toLowerCase() != 'romfs') {
        continue;
      }
      return _ArchivePathMatch(
        segments[index + 2].toUpperCase(),
        segments.skip(index + 4).join('/'),
        segments
            .take(index + 4)
            .map((segment) => segment.toLowerCase())
            .join('/'),
      );
    }
    return null;
  }

  void _validateFiles(List<_PatchFile> files) {
    for (final file in files) {
      if (file.size < 0) {
        throw FormatException('无法确定补丁文件大小：${file.relativePath}');
      }
      _validateRelativePath(file.relativePath);
    }
    files.sort(
      (left, right) =>
          _comparePatchPaths(left.relativePath, right.relativePath),
    );
    for (var index = 1; index < files.length; index++) {
      if (_comparePatchPaths(
            files[index - 1].relativePath,
            files[index].relativePath,
          ) ==
          0) {
        throw FormatException('补丁包含重复路径：${files[index].relativePath}');
      }
    }
  }

  int _comparePatchPaths(String left, String right) {
    final leftBytes = utf8.encode(left);
    final rightBytes = utf8.encode(right);
    final common = min(leftBytes.length, rightBytes.length);
    for (var index = 0; index < common; index++) {
      final leftByte = _asciiLower(leftBytes[index]);
      final rightByte = _asciiLower(rightBytes[index]);
      if (leftByte != rightByte) return leftByte.compareTo(rightByte);
    }
    return leftBytes.length.compareTo(rightBytes.length);
  }

  int _asciiLower(int byte) =>
      byte >= 0x41 && byte <= 0x5a ? byte + 0x20 : byte;

  void _validateRelativePath(String path) {
    final bytes = utf8.encode(path);
    final segments = path.split('/');
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        bytes.length > patchBundleMaxPathBytes ||
        bytes.length > patchReceiverMaxRelativePathBytes ||
        segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw FormatException('补丁包含不安全的相对路径：$path');
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static String _basename(String path) {
    final parts = path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? 'LayeredFS patch' : parts.last;
  }

  static bool _isTitleId(String value) =>
      RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(value);

  static String _join(
    String first,
    String second, [
    String? third,
    String? fourth,
    String? fifth,
  ]) => [
    first,
    second,
    ?third,
    ?fourth,
    ?fifth,
  ].where((part) => part.isNotEmpty).join(Platform.pathSeparator);
}

class Crc32 {
  static final Uint32List _table = Uint32List.fromList(
    List<int>.generate(256, (index) {
      var value = index;
      for (var bit = 0; bit < 8; bit++) {
        value = (value & 1) != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1;
      }
      return value & 0xffffffff;
    }, growable: false),
  );

  int _value = 0xffffffff;

  void add(List<int> bytes) {
    for (final byte in bytes) {
      _value = ((_value >> 8) ^ _table[(_value ^ byte) & 0xff]) & 0xffffffff;
    }
  }

  int get value => (_value ^ 0xffffffff) & 0xffffffff;
}

class _PatchSource {
  _PatchSource({
    required this.titleId,
    required this.label,
    required this.romfsPath,
    required this.files,
    this.onClose,
  });

  final String titleId;
  final String label;
  final String romfsPath;
  final List<_PatchFile> files;
  final Future<void> Function()? onClose;

  Future<void> close() async => onClose?.call();
}

class _PatchTarget {
  const _PatchTarget(this.titleId, this.romfs);

  final String titleId;
  final Directory romfs;
}

class _PatchFile {
  _PatchFile({
    required this.relativePath,
    required this.size,
    this.localFile,
    this.openRead,
    this.materialize,
    this.expectedCrc32,
  });

  final String relativePath;
  final int size;
  final File? localFile;
  final Stream<List<int>> Function()? openRead;
  final Future<void> Function(File target)? materialize;
  final int? expectedCrc32;
}

class _ArchivePathMatch {
  const _ArchivePathMatch(this.titleId, this.relativePath, this.rootKey);

  final String titleId;
  final String relativePath;
  final String rootKey;
}
