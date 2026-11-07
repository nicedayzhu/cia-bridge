import 'dart:io';

import 'package:cia_bridge/core/models.dart';
import 'package:cia_bridge/core/patch_bundle.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/build_patch.dart <LayeredFS directory-or-zip> <output.cbpatch>',
    );
    exitCode = 64;
    return;
  }

  PreparedPatch? prepared;
  try {
    prepared = await const PatchBundleBuilder().build(
      arguments[0],
      onProgress: (completed, total, path) {
        if (completed == total || completed % 100 == 0) {
          stdout.writeln('$completed/$total $path');
        }
      },
    );
    final output = File(arguments[1]);
    await output.parent.create(recursive: true);
    await File(prepared.file.path!).copy(output.path);
    stdout.writeln(
      'Title ID ${prepared.titleId}; ${prepared.fileCount} files; '
      '${formatBytes(prepared.rawBytes)} raw; '
      '${formatBytes(await output.length())} bundle; ${output.absolute.path}',
    );
  } finally {
    await prepared?.delete();
  }
}
