import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'models.dart';

class DesktopLanServer {
  HttpServer? _server;
  Map<String, ShareFile> _filesByPath = const {};
  void Function(HostEvent event)? onEvent;
  var _sessionBytes = 0;
  var _sessionTotal = 0;

  Future<HostingSession> start({
    required List<ShareFile> files,
    required String advertisedAddress,
    required int preferredPort,
  }) async {
    await stop();
    if (files.isEmpty) throw ArgumentError('至少需要一个文件');
    if (files.any((file) => file.path == null)) {
      throw ArgumentError('Windows 文件缺少本地路径');
    }

    var usedFallback = false;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      if (preferredPort == 0) rethrow;
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      usedFallback = true;
    }

    final token = _randomToken();
    final entries = <String, ShareFile>{};
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      entries['/$token/${index + 1}/${_safeName(file.name)}'] = file;
    }
    _filesByPath = entries;
    _sessionBytes = 0;
    _sessionTotal = files.fold<int>(0, (total, file) => total + file.size);
    _server = server;
    unawaited(server.forEach(_handleRequest));

    final urls = entries.keys
        .map(
          (path) =>
              'http://$advertisedAddress:${server.port}${_encodePath(path)}',
        )
        .toList(growable: false);
    return HostingSession(
      urls: urls,
      port: server.port,
      totalBytes: _sessionTotal,
      usedFallbackPort: usedFallback,
    );
  }

  Future<void> stop() async {
    final current = _server;
    _server = null;
    _filesByPath = const {};
    if (current != null) {
      await current.close(force: true);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    final requestPath = Uri.decodeComponent(request.uri.path);
    final file = _filesByPath[requestPath] ?? _filesByPath[request.uri.path];
    if (file == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    try {
      final range = _parseRange(
        request.headers.value(HttpHeaders.rangeHeader),
        file.size,
      );
      final contentLength = range.endExclusive - range.start;
      response.statusCode = range.partial
          ? HttpStatus.partialContent
          : HttpStatus.ok;
      response.headers
        ..contentType = ContentType.binary
        ..contentLength = contentLength
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(
          'content-disposition',
          "attachment; filename*=UTF-8''${Uri.encodeComponent(file.name)}",
        )
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      if (range.partial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.endExclusive - 1}/${file.size}',
        );
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }

      onEvent?.call(
        HostEvent(
          type: HostEventType.downloadStarted,
          fileName: file.name,
          fileSize: file.size,
          sessionTotal: _sessionTotal,
        ),
      );
      var fileBytes = range.start;
      var reportedAt = fileBytes;
      final stream = File(file.path!)
          .openRead(range.start, range.endExclusive)
          .map((chunk) {
            fileBytes += chunk.length;
            _sessionBytes += chunk.length;
            if (fileBytes - reportedAt >= 256 * 1024 ||
                fileBytes == range.endExclusive) {
              reportedAt = fileBytes;
              onEvent?.call(
                HostEvent(
                  type: HostEventType.progress,
                  fileName: file.name,
                  fileBytes: fileBytes,
                  fileSize: file.size,
                  sessionBytes: _sessionBytes,
                  sessionTotal: _sessionTotal,
                ),
              );
            }
            return chunk;
          });
      await response.addStream(stream);
      await response.close();
      onEvent?.call(
        HostEvent(
          type: HostEventType.downloadFinished,
          fileName: file.name,
          fileSize: file.size,
          sessionBytes: _sessionBytes,
          sessionTotal: _sessionTotal,
        ),
      );
    } on _InvalidRange {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${file.size}',
      );
      await response.close();
    } catch (error) {
      onEvent?.call(
        HostEvent(type: HostEventType.error, message: error.toString()),
      );
      try {
        await response.close();
      } catch (_) {}
    }
  }
}

class _ByteRange {
  const _ByteRange(this.start, this.endExclusive, this.partial);

  final int start;
  final int endExclusive;
  final bool partial;
}

class _InvalidRange implements Exception {}

_ByteRange _parseRange(String? header, int size) {
  if (header == null || header.isEmpty) return _ByteRange(0, size, false);
  if (!header.startsWith('bytes=') || header.contains(',')) {
    throw _InvalidRange();
  }
  final value = header.substring(6).trim();
  final dash = value.indexOf('-');
  if (dash < 0 || size <= 0) throw _InvalidRange();
  try {
    if (dash == 0) {
      final suffix = int.parse(value.substring(1));
      if (suffix <= 0) throw _InvalidRange();
      return _ByteRange(max(0, size - suffix), size, true);
    }
    final start = int.parse(value.substring(0, dash));
    final end = dash == value.length - 1
        ? size - 1
        : int.parse(value.substring(dash + 1));
    if (start < 0 || start >= size || end < start) throw _InvalidRange();
    return _ByteRange(start, min(end, size - 1) + 1, true);
  } on FormatException {
    throw _InvalidRange();
  }
}

String _randomToken() {
  final random = Random.secure();
  return List.generate(
    6,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _safeName(String value) {
  final clean = value.replaceAll(RegExp(r'[\\/]'), '_').trim();
  return clean.isEmpty ? 'download.cia' : clean;
}

String _encodePath(String decodedPath) {
  return decodedPath
      .split('/')
      .map((part) => Uri.encodeComponent(part))
      .join('/');
}
