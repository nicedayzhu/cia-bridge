import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cia_bridge/core/patch_bundle.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('computes the standard CRC32 test vector', () {
    final crc = Crc32()..add(ascii.encode('123456789'));
    expect(crc.value, 0xcbf43926);
  });

  test('derives a stable bundle ID from canonical record metadata', () async {
    final patches = <PreparedPatch>[];

    PatchInputFile inputFile(String id, String path, List<int> bytes) {
      return PatchInputFile(
        id: id,
        relativePath: path,
        size: bytes.length,
        openRead: () => Stream<List<int>>.value(bytes),
      );
    }

    Future<PreparedPatch> build(
      String label,
      List<PatchInputFile> files,
    ) async {
      final patch = await const PatchBundleBuilder().buildInput(
        PatchInput.streamed(
          titleId: '0004000000194200',
          label: label,
          files: files,
        ),
      );
      patches.add(patch);
      return patch;
    }

    try {
      final first = await build('first source', [
        inputFile('source-z', 'z.bin', const [9, 8, 7]),
        inputFile('source-a', 'a.bin', const [1, 2, 3, 4]),
      ]);
      final second = await build('different label', [
        inputFile('other-a', 'a.bin', const [1, 2, 3, 4]),
        inputFile('other-z', 'z.bin', const [9, 8, 7]),
      ]);

      expect(second.bundleId, first.bundleId);
      expect(first.bundleId, 'e86186d4f27a532f96492033ae609888');
      for (final patch in [first, second]) {
        final header = await File(patch.file.path!)
            .openRead(48, 64)
            .fold(<int>[], (bytes, chunk) => bytes..addAll(chunk));
        expect(_hex(header), patch.bundleId);
      }

      final changedContent = await build('same size, changed CRC', [
        inputFile('source-a', 'a.bin', const [1, 2, 3, 5]),
        inputFile('source-z', 'z.bin', const [9, 8, 7]),
      ]);
      expect(changedContent.bundleId, isNot(first.bundleId));

      final changedPath = await build('same bytes, changed path', [
        inputFile('source-a', 'renamed.bin', const [1, 2, 3, 4]),
        inputFile('source-z', 'z.bin', const [9, 8, 7]),
      ]);
      expect(changedPath.bundleId, isNot(first.bundleId));
    } finally {
      for (final patch in patches) {
        await patch.delete();
      }
    }
  });

  test('builds a deterministic, recoverable CBPATCH1 record stream', () async {
    final root = await Directory.systemTemp.createTemp('cbpatch_test_');
    PreparedPatch? patch;
    try {
      final romfs = Directory(
        '${root.path}${Platform.pathSeparator}luma${Platform.pathSeparator}'
        'titles${Platform.pathSeparator}0004000000194200'
        '${Platform.pathSeparator}romfs',
      );
      await Directory('${romfs.path}${Platform.pathSeparator}script')
          .create(recursive: true);
      await File(
        '${romfs.path}${Platform.pathSeparator}script'
        '${Platform.pathSeparator}dialog.bin',
      ).writeAsBytes(List<int>.filled(4096, 0x41));
      await File('${romfs.path}${Platform.pathSeparator}boot.bin')
          .writeAsBytes(List<int>.generate(1024, (index) => index & 0xff));

      patch = await const PatchBundleBuilder().build(root.path);
      expect(patch.titleId, '0004000000194200');
      expect(patch.fileCount, 2);
      expect(patch.rawBytes, 5120);

      final bytes = await File(patch.file.path!).readAsBytes();
      final header = ByteData.sublistView(bytes, 0, patchBundleHeaderSize);
      expect(ascii.decode(bytes.sublist(0, 8)), patchBundleMagic);
      expect(header.getUint32(8, Endian.little), patchBundleHeaderSize);
      expect(
        header.getUint64(16, Endian.little).toRadixString(16).padLeft(16, '0'),
        '0004000000194200',
      );
      expect(header.getUint32(24, Endian.little), 2);
      expect(_hex(bytes.sublist(48, 64)), patch.bundleId);
      final crc = Crc32()..add(bytes.sublist(0, 64));
      expect(header.getUint32(64, Endian.little), crc.value);

      var offset = patchBundleHeaderSize;
      final restored = <String, List<int>>{};
      final codecs = <PatchCodec>[];
      for (var index = 0; index < 2; index++) {
        final record = ByteData.sublistView(
          bytes,
          offset,
          offset + patchBundleRecordHeaderSize,
        );
        offset += patchBundleRecordHeaderSize;
        final pathLength = record.getUint16(0, Endian.little);
        final codec = PatchCodec.values[record.getUint8(2)];
        codecs.add(codec);
        final rawSize = record.getUint64(4, Endian.little);
        final storedSize = record.getUint64(12, Endian.little);
        final expectedCrc = record.getUint32(20, Endian.little);
        final path = utf8.decode(bytes.sublist(offset, offset + pathLength));
        offset += pathLength;
        final stored = bytes.sublist(offset, offset + storedSize);
        offset += storedSize;
        expect(codec, PatchCodec.raw);
        final raw = stored;
        expect(raw.length, rawSize);
        final actualCrc = Crc32()..add(raw);
        expect(actualCrc.value, expectedCrc);
        restored[path] = raw;
      }

      expect(restored.keys, ['boot.bin', 'script/dialog.bin']);
      expect(restored['script/dialog.bin'], List<int>.filled(4096, 0x41));
      expect(codecs, everyElement(PatchCodec.raw));
      expect(patch.storedBytes, patch.rawBytes);
      expect(offset, bytes.length);
    } finally {
      if (patch != null) await patch.delete();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('rejects a directory containing multiple title IDs', () async {
    final root = await Directory.systemTemp.createTemp('cbpatch_multi_');
    try {
      for (final titleId in ['0004000000194200', '0004000000123400']) {
        final romfs = Directory(
          '${root.path}${Platform.pathSeparator}luma${Platform.pathSeparator}'
          'titles${Platform.pathSeparator}$titleId'
          '${Platform.pathSeparator}romfs',
        );
        await romfs.create(recursive: true);
        await File('${romfs.path}${Platform.pathSeparator}file.bin')
            .writeAsBytes([1]);
      }
      await expectLater(
        const PatchBundleBuilder().build(root.path),
        throwsA(isA<FormatException>()),
      );
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('reads a LayeredFS ZIP without requiring a patch manifest', () async {
    final root = await Directory.systemTemp.createTemp('cbpatch_zip_');
    PreparedPatch? patch;
    try {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'Corpse Party patch/luma/titles/0004000000194200/'
                'romfs/script/dialog.bin',
            'translated text',
          ),
        )
        ..addFile(ArchiveFile.string('Corpse Party patch/README.txt', 'help'));
      final zip = File('${root.path}${Platform.pathSeparator}corpse-party.zip');
      await zip.writeAsBytes(ZipEncoder().encode(archive));

      patch = await const PatchBundleBuilder().build(zip.path);

      expect(patch.titleId, '0004000000194200');
      expect(patch.fileCount, 1);
      expect(patch.sourceLabel, 'corpse-party');
      expect(patch.rawBytes, utf8.encode('translated text').length);
    } finally {
      if (patch != null) await patch.delete();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('rejects multiple romfs roots even when the title ID matches', () async {
    final root = await Directory.systemTemp.createTemp('cbpatch_zip_roots_');
    try {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'first/luma/titles/0004000000194200/romfs/one.bin',
            'one',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'second/luma/titles/0004000000194200/romfs/two.bin',
            'two',
          ),
        );
      final zip = File('${root.path}${Platform.pathSeparator}ambiguous.zip');
      await zip.writeAsBytes(ZipEncoder().encode(archive));

      await expectLater(
        const PatchBundleBuilder().build(zip.path),
        throwsA(isA<FormatException>()),
      );
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('builds from a streamed Android-style directory source', () async {
    PreparedPatch? patch;
    try {
      const bytes = <int>[1, 2, 3, 4, 5];
      patch = await const PatchBundleBuilder().buildInput(
        PatchInput.streamed(
          titleId: '0004000000194200',
          label: 'Corpse Party patch',
          files: [
            PatchInputFile(
              id: 'content://patch/file.bin',
              relativePath: 'data/file.bin',
              size: bytes.length,
              openRead: _streamedTestBytes,
            ),
          ],
        ),
      );

      expect(patch.titleId, '0004000000194200');
      expect(patch.fileCount, 1);
      expect(patch.rawBytes, bytes.length);
    } finally {
      if (patch != null) await patch.delete();
    }
  });
}

Stream<List<int>> _streamedTestBytes() async* {
  yield const [1, 2, 3, 4, 5];
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
