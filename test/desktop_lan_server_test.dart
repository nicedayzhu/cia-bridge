import 'dart:io';

import 'package:cia_bridge/core/desktop_lan_server.dart';
import 'package:cia_bridge/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;
  late File testFile;
  late DesktopLanServer server;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'cia-bridge-test-',
    );
    testFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}测试 file.cia',
    );
    await testFile.writeAsBytes(
      List<int>.generate(4096, (index) => index % 251),
    );
    server = DesktopLanServer();
  });

  tearDown(() async {
    await server.stop();
    await temporaryDirectory.delete(recursive: true);
  });

  test('streams a selected file with a fixed content length', () async {
    final session = await server.start(
      files: [
        ShareFile(
          id: testFile.path,
          name: '测试 file.cia',
          size: await testFile.length(),
          path: testFile.path,
        ),
      ],
      advertisedAddress: '127.0.0.1',
      preferredPort: 0,
    );

    final client = HttpClient();
    final response = await (await client.getUrl(Uri.parse(session.urls.single)))
        .close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, 4096);
    expect(bytes.length, 4096);
    expect(bytes[251], 0);
    client.close();
  });

  test('supports byte ranges used when a download resumes', () async {
    final session = await server.start(
      files: [
        ShareFile(
          id: testFile.path,
          name: 'resume.cia',
          size: await testFile.length(),
          path: testFile.path,
        ),
      ],
      advertisedAddress: '127.0.0.1',
      preferredPort: 0,
    );

    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(session.urls.single));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 100-199/4096',
    );
    expect(bytes.length, 100);
    expect(bytes.first, 100);
    client.close();
  });
}
