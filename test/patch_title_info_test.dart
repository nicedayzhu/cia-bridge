import 'dart:io';

import 'package:cia_bridge/core/patch_title_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'resolves Corpse Party from the bundled offline title catalog',
    () async {
      final root = await Directory.systemTemp.createTemp('title_info_test_');
      try {
        final info = await PatchTitleInfoService().resolve(
          '0004000000194200',
          dataDirectory: root.path,
          allowNetwork: false,
        );

        expect(info, isNotNull);
        expect(info!.name, 'Corpse Party');
        expect(info.titleId, '0004000000194200');
        expect(info.source, PatchTitleInfoSource.bundled);
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );
}
