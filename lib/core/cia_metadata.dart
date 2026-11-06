import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

typedef CiaRangeReader = Future<Uint8List> Function({
  required int offset,
  required int length,
});

class CiaMetadataParser {
  const CiaMetadataParser();

  static const _ciaHeaderFieldsSize = 0x20;
  static const _smdhSize = 0x36c0;
  static const _smdhMetaOffset = 0x400;
  static const _largeIconOffset = 0x24c0;
  static const _largeIconSize = 0x1200;

  Future<CiaMetadata> parse({
    required int fileSize,
    required CiaRangeReader readRange,
  }) async {
    if (fileSize < _ciaHeaderFieldsSize) {
      throw const FormatException('CIA 文件小于最小头部长度');
    }

    final header = await _readExact(
      readRange,
      offset: 0,
      length: _ciaHeaderFieldsSize,
    );
    final view = ByteData.sublistView(header);
    final headerSize = view.getUint32(0x00, Endian.little);
    final certificateSize = view.getUint32(0x08, Endian.little);
    final ticketSize = view.getUint32(0x0c, Endian.little);
    final tmdSize = view.getUint32(0x10, Endian.little);
    final metaSize = view.getUint32(0x14, Endian.little);
    final contentSize = view.getUint64(0x18, Endian.little);

    if (headerSize < _ciaHeaderFieldsSize || headerSize > fileSize) {
      throw const FormatException('CIA 头部长度无效');
    }
    if (tmdSize == 0) throw const FormatException('CIA 缺少 TMD');

    final certificateOffset = _align64(headerSize);
    final ticketOffset = _align64(
      _sectionEnd(certificateOffset, certificateSize, fileSize, '证书链'),
    );
    final tmdOffset = _align64(
      _sectionEnd(ticketOffset, ticketSize, fileSize, 'Ticket'),
    );
    final contentOffset = _align64(
      _sectionEnd(tmdOffset, tmdSize, fileSize, 'TMD'),
    );
    final metaOffset = _align64(
      _sectionEnd(contentOffset, contentSize, fileSize, '内容区'),
    );
    if (metaSize > 0) {
      _sectionEnd(metaOffset, metaSize, fileSize, 'Meta');
    }

    final tmd = await _readExact(
      readRange,
      offset: tmdOffset,
      length: tmdSize < 0x300 ? tmdSize : 0x300,
    );
    final tmdInfo = _parseTmd(tmd);

    _SmdhInfo? smdh;
    String? metaReadError;
    if (metaSize >= _smdhMetaOffset + _smdhSize) {
      try {
        final bytes = await _readExact(
          readRange,
          offset: metaOffset + _smdhMetaOffset,
          length: _smdhSize,
        );
        smdh = _parseSmdh(bytes);
      } on Object catch (error) {
        metaReadError = _shortError(error);
      }
    } else if (metaSize > 0) {
      metaReadError = 'CIA Meta 区不包含完整的 SMDH';
    }

    return CiaMetadata(
      titleId: tmdInfo.titleId,
      titleVersion: tmdInfo.version,
      kind: _kindFromTitleId(tmdInfo.titleId),
      shortTitle: smdh?.shortTitle,
      longTitle: smdh?.longTitle,
      publisher: smdh?.publisher,
      regionMask: smdh?.regionMask,
      smdhFlags: smdh?.flags,
      iconPng: smdh?.iconPng,
      metaReadError: metaReadError,
    );
  }

  Future<Uint8List> _readExact(
    CiaRangeReader reader, {
    required int offset,
    required int length,
  }) async {
    final bytes = await reader(offset: offset, length: length);
    if (bytes.length != length) {
      throw FormatException('读取 CIA 数据不完整：需要 $length 字节，实际 ${bytes.length} 字节');
    }
    return bytes;
  }

  _TmdInfo _parseTmd(Uint8List bytes) {
    if (bytes.length < 4) throw const FormatException('TMD 头部不完整');
    final view = ByteData.sublistView(bytes);
    final signatureType = view.getUint32(0, Endian.big);
    final bodyOffset = switch (signatureType) {
      0x00010000 || 0x00010003 => 0x240,
      0x00010001 || 0x00010004 => 0x140,
      0x00010002 || 0x00010005 => 0x080,
      _ => throw FormatException(
        '不支持的 TMD 签名类型 0x${signatureType.toRadixString(16)}',
      ),
    };
    if (bytes.length < bodyOffset + 0x9e) {
      throw const FormatException('TMD 数据不完整');
    }
    final titleIdBytes = bytes.sublist(bodyOffset + 0x4c, bodyOffset + 0x54);
    final titleId = titleIdBytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final version = view.getUint16(bodyOffset + 0x9c, Endian.big);
    return _TmdInfo(titleId, version);
  }

  _SmdhInfo _parseSmdh(Uint8List bytes) {
    if (bytes.length != _smdhSize ||
        bytes[0] != 0x53 ||
        bytes[1] != 0x4d ||
        bytes[2] != 0x44 ||
        bytes[3] != 0x48) {
      throw const FormatException('CIA Meta 中没有有效的 SMDH');
    }

    const preferredLanguages = [6, 11, 1, 0, 2, 3, 4, 5, 7, 8, 9, 10];
    String? shortTitle;
    String? longTitle;
    String? publisher;
    for (final index in preferredLanguages) {
      final start = 0x08 + index * 0x200;
      final candidateShort = _readUtf16Le(bytes, start, 0x80);
      final candidateLong = _readUtf16Le(bytes, start + 0x80, 0x100);
      if (candidateShort.isEmpty && candidateLong.isEmpty) continue;
      shortTitle = candidateShort.isEmpty ? null : candidateShort;
      longTitle = candidateLong.isEmpty ? null : candidateLong;
      final candidatePublisher = _readUtf16Le(bytes, start + 0x180, 0x80);
      publisher = candidatePublisher.isEmpty ? null : candidatePublisher;
      break;
    }
    if (publisher == null) {
      for (final index in preferredLanguages) {
        final candidate = _readUtf16Le(
          bytes,
          0x08 + index * 0x200 + 0x180,
          0x80,
        );
        if (candidate.isNotEmpty) {
          publisher = candidate;
          break;
        }
      }
    }

    final view = ByteData.sublistView(bytes);
    return _SmdhInfo(
      shortTitle: shortTitle,
      longTitle: longTitle,
      publisher: publisher,
      regionMask: view.getUint32(0x2018, Endian.little),
      flags: view.getUint32(0x2028, Endian.little),
      iconPng: _largeIconToPng(
        bytes.sublist(_largeIconOffset, _largeIconOffset + _largeIconSize),
      ),
    );
  }

  String _readUtf16Le(Uint8List bytes, int offset, int byteLength) {
    final units = <int>[];
    final view = ByteData.sublistView(bytes);
    for (var cursor = offset; cursor < offset + byteLength; cursor += 2) {
      final unit = view.getUint16(cursor, Endian.little);
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units).trim();
  }

  Uint8List _largeIconToPng(Uint8List source) {
    const width = 48;
    const height = 48;
    final scanlines = Uint8List(height * (1 + width * 4));
    for (var y = 0; y < height; y++) {
      final rowStart = y * (1 + width * 4);
      scanlines[rowStart] = 0;
      for (var x = 0; x < width; x++) {
        final tile = ((y >> 3) * (width >> 3) + (x >> 3)) * 64;
        final pixel = tile + _mortonIndex(x & 7, y & 7);
        final raw = source[pixel * 2] | (source[pixel * 2 + 1] << 8);
        final target = rowStart + 1 + x * 4;
        scanlines[target] = ((raw >> 11) & 0x1f) * 255 ~/ 31;
        scanlines[target + 1] = ((raw >> 5) & 0x3f) * 255 ~/ 63;
        scanlines[target + 2] = (raw & 0x1f) * 255 ~/ 31;
        scanlines[target + 3] = 0xff;
      }
    }
    return _encodePngRgba(width, height, scanlines);
  }

  int _mortonIndex(int x, int y) {
    var result = 0;
    for (var bit = 0; bit < 3; bit++) {
      result |= ((x >> bit) & 1) << (bit * 2);
      result |= ((y >> bit) & 1) << (bit * 2 + 1);
    }
    return result;
  }

  Uint8List _encodePngRgba(int width, int height, Uint8List scanlines) {
    final output = BytesBuilder(copy: false)
      ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    final header = ByteData(13)
      ..setUint32(0, width, Endian.big)
      ..setUint32(4, height, Endian.big)
      ..setUint8(8, 8)
      ..setUint8(9, 6)
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);
    _writePngChunk(output, 'IHDR', header.buffer.asUint8List());
    _writePngChunk(
      output,
      'IDAT',
      Uint8List.fromList(ZLibEncoder().convert(scanlines)),
    );
    _writePngChunk(output, 'IEND', Uint8List(0));
    return output.takeBytes();
  }

  void _writePngChunk(BytesBuilder output, String type, Uint8List data) {
    final typeBytes = Uint8List.fromList(type.codeUnits);
    final length = ByteData(4)..setUint32(0, data.length, Endian.big);
    final crcInput = BytesBuilder(copy: false)
      ..add(typeBytes)
      ..add(data);
    final crc = ByteData(4)
      ..setUint32(0, _crc32(crcInput.takeBytes()), Endian.big);
    output
      ..add(length.buffer.asUint8List())
      ..add(typeBytes)
      ..add(data)
      ..add(crc.buffer.asUint8List());
  }

  int _crc32(Uint8List bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  int _align64(int value) => (value + 0x3f) & ~0x3f;

  int _sectionEnd(int offset, int size, int fileSize, String label) {
    if (offset < 0 ||
        size < 0 ||
        offset > fileSize ||
        size > fileSize - offset) {
      throw FormatException('CIA $label 范围超出文件长度');
    }
    return offset + size;
  }

  CiaTitleKind _kindFromTitleId(String titleId) {
    final high = titleId.substring(0, 8);
    if (high == '00040000') return CiaTitleKind.application;
    if (high == '00040002') return CiaTitleKind.demo;
    if (high == '0004000E') return CiaTitleKind.update;
    if (high == '0004008C') return CiaTitleKind.downloadableContent;
    if (high.startsWith('000480')) return CiaTitleKind.dsiWare;
    if (high == '00040010' ||
        high == '0004001B' ||
        high == '00040030' ||
        high == '0004009B' ||
        high == '000400DB' ||
        high.startsWith('000401')) {
      return CiaTitleKind.system;
    }
    return CiaTitleKind.unknown;
  }

  String _shortError(Object error) => error
      .toString()
      .replaceFirst(RegExp(r'^(FormatException|FileSystemException):\s*'), '')
      .trim();
}

class _TmdInfo {
  const _TmdInfo(this.titleId, this.version);

  final String titleId;
  final int version;
}

class _SmdhInfo {
  const _SmdhInfo({
    required this.shortTitle,
    required this.longTitle,
    required this.publisher,
    required this.regionMask,
    required this.flags,
    required this.iconPng,
  });

  final String? shortTitle;
  final String? longTitle;
  final String? publisher;
  final int regionMask;
  final int flags;
  final Uint8List iconPng;
}
