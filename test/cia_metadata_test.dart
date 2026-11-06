import 'dart:io';
import 'dart:typed_data';

import 'package:cia_bridge/core/cia_metadata.dart';
import 'package:cia_bridge/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = CiaMetadataParser();

  test(
    'reads local title data and SMDH artwork without scanning the CIA',
    () async {
      final cia = _buildCia();
      final reads = <(int, int)>[];

      final metadata = await parser.parse(
        fileSize: cia.length,
        readRange: ({required offset, required length}) async {
          reads.add((offset, length));
          return Uint8List.fromList(cia.sublist(offset, offset + length));
        },
      );

      expect(metadata.titleId, '000400000FF40A00');
      expect(metadata.titleVersion, 2069);
      expect(metadata.versionLabel, 'v2.1.5');
      expect(metadata.kind, CiaTitleKind.application);
      expect(metadata.shortTitle, '测试软件');
      expect(metadata.longTitle, 'CIA Bridge 测试软件');
      expect(metadata.publisher, '本地发行者');
      expect(metadata.regionLabel, '美/中');
      expect(metadata.isNew3dsOnly, isTrue);
      expect(metadata.iconPng, isNotNull);
      expect(metadata.iconPng!.sublist(0, 8), [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);

      final rgba = _decodePngScanlines(metadata.iconPng!);
      const stride = 1 + 48 * 4;
      expect(rgba.sublist(1, 5), [255, 0, 0, 255]);
      expect(rgba.sublist(5, 9), [0, 255, 0, 255]);
      expect(rgba.sublist(stride + 1, stride + 5), [0, 0, 255, 255]);
      expect(reads.map((read) => read.$2), [0x20, 0x300, 0x36c0]);
    },
  );

  test('keeps TMD information when optional SMDH cannot be read', () async {
    final cia = _buildCia();

    final metadata = await parser.parse(
      fileSize: cia.length,
      readRange: ({required offset, required length}) async {
        if (length == 0x36c0) {
          throw const FileSystemException('random access unavailable');
        }
        return Uint8List.fromList(cia.sublist(offset, offset + length));
      },
    );

    expect(metadata.titleId, '000400000FF40A00');
    expect(metadata.displayTitle, isNull);
    expect(metadata.metaReadError, contains('random access unavailable'));
  });

  test('rejects section ranges outside the selected file', () async {
    final cia = _buildCia();
    ByteData.sublistView(cia).setUint64(0x18, cia.length, Endian.little);

    expect(
      () => parser.parse(
        fileSize: cia.length,
        readRange: ({required offset, required length}) async =>
            Uint8List.fromList(cia.sublist(offset, offset + length)),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

Uint8List _buildCia() {
  const headerSize = 0x2020;
  const tmdOffset = 0x2040;
  const tmdSize = 0x300;
  const metaOffset = 0x2340;
  const metaSize = 0x3ac0;
  final bytes = Uint8List(metaOffset + metaSize);
  final view = ByteData.sublistView(bytes);

  view
    ..setUint32(0x00, headerSize, Endian.little)
    ..setUint32(0x08, 0, Endian.little)
    ..setUint32(0x0c, 0, Endian.little)
    ..setUint32(0x10, tmdSize, Endian.little)
    ..setUint32(0x14, metaSize, Endian.little)
    ..setUint64(0x18, 0, Endian.little)
    ..setUint32(tmdOffset, 0x00010004, Endian.big);

  const tmdBody = tmdOffset + 0x140;
  final titleId = Uint8List.fromList([
    0x00,
    0x04,
    0x00,
    0x00,
    0x0f,
    0xf4,
    0x0a,
    0x00,
  ]);
  bytes.setRange(tmdBody + 0x4c, tmdBody + 0x54, titleId);
  view.setUint16(tmdBody + 0x9c, 2069, Endian.big);

  const smdh = metaOffset + 0x400;
  bytes.setRange(smdh, smdh + 4, 'SMDH'.codeUnits);
  _writeUtf16(bytes, smdh + 0x08, 'Japanese fallback');
  const chineseTitle = smdh + 0x08 + 6 * 0x200;
  _writeUtf16(bytes, chineseTitle, '测试软件');
  _writeUtf16(bytes, chineseTitle + 0x80, 'CIA Bridge 测试软件');
  _writeUtf16(bytes, chineseTitle + 0x180, '本地发行者');
  view
    ..setUint32(smdh + 0x2018, 0x12, Endian.little)
    ..setUint32(smdh + 0x2028, 0x1000, Endian.little);

  const icon = smdh + 0x24c0;
  view
    ..setUint16(icon, 0xf800, Endian.little)
    ..setUint16(icon + 2, 0x07e0, Endian.little)
    ..setUint16(icon + 4, 0x001f, Endian.little);
  return bytes;
}

void _writeUtf16(Uint8List bytes, int offset, String value) {
  final view = ByteData.sublistView(bytes);
  for (var index = 0; index < value.codeUnits.length; index++) {
    view.setUint16(offset + index * 2, value.codeUnitAt(index), Endian.little);
  }
}

Uint8List _decodePngScanlines(Uint8List png) {
  var offset = 8;
  final compressed = BytesBuilder(copy: false);
  while (offset < png.length) {
    final view = ByteData.sublistView(png, offset, offset + 4);
    final length = view.getUint32(0, Endian.big);
    final type = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
    final dataStart = offset + 8;
    if (type == 'IDAT') {
      compressed.add(png.sublist(dataStart, dataStart + length));
    }
    offset = dataStart + length + 4;
    if (type == 'IEND') break;
  }
  return Uint8List.fromList(ZLibDecoder().convert(compressed.takeBytes()));
}
