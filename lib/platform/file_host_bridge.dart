import 'dart:io';

import 'package:flutter/services.dart';

import '../core/desktop_lan_server.dart';
import '../core/models.dart';

abstract class FileHostBridge {
  factory FileHostBridge() {
    if (Platform.isAndroid) return AndroidFileHostBridge();
    if (Platform.isWindows) return WindowsFileHostBridge();
    throw UnsupportedError('CIA Bridge currently supports Windows and Android');
  }

  void Function(HostEvent event)? onEvent;

  Future<List<ShareFile>> pickFiles();

  Future<Uint8List> readFileRange(
    ShareFile file, {
    required int offset,
    required int length,
  }) => Future<Uint8List>.error(
    UnsupportedError('This platform cannot inspect CIA files'),
  );

  Future<List<NetworkNeighbor>> listNeighbors(String localAddress);

  Future<HostingSession> start({
    required List<ShareFile> files,
    required String advertisedAddress,
    required int preferredPort,
  });

  Future<void> stop();
}

class WindowsFileHostBridge implements FileHostBridge {
  static const _channel = MethodChannel('cia_bridge/native');
  final DesktopLanServer _server = DesktopLanServer();

  @override
  void Function(HostEvent event)? onEvent;

  @override
  Future<List<ShareFile>> pickFiles() async {
    final rawFiles =
        await _channel.invokeListMethod<Object?>('pickFiles') ?? [];
    return rawFiles
        .map((raw) {
          final map = Map<Object?, Object?>.from(raw as Map);
          final path = map['path'] as String;
          return ShareFile(
            id: path,
            name: map['name'] as String,
            size: (map['size'] as num).toInt(),
            path: path,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<Uint8List> readFileRange(
    ShareFile file, {
    required int offset,
    required int length,
  }) async {
    final path = file.path;
    if (path == null) throw StateError('Windows 文件缺少本地路径');
    if (offset < 0 || length < 0) throw RangeError('文件读取范围无效');
    final handle = await File(path).open();
    try {
      await handle.setPosition(offset);
      final bytes = await handle.read(length);
      if (bytes.length != length) {
        throw const FileSystemException('CIA 文件读取不完整');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  @override
  Future<List<NetworkNeighbor>> listNeighbors(String localAddress) =>
      _readNeighbors(_channel, localAddress);

  @override
  Future<HostingSession> start({
    required List<ShareFile> files,
    required String advertisedAddress,
    required int preferredPort,
  }) {
    _server.onEvent = (event) => onEvent?.call(event);
    return _server.start(
      files: files,
      advertisedAddress: advertisedAddress,
      preferredPort: preferredPort,
    );
  }

  @override
  Future<void> stop() => _server.stop();
}

class AndroidFileHostBridge implements FileHostBridge {
  static const _channel = MethodChannel('cia_bridge/native');

  AndroidFileHostBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'transferEvent') return;
      final raw = Map<Object?, Object?>.from(call.arguments as Map);
      final typeName = raw['type'] as String? ?? 'error';
      final type = HostEventType.values.firstWhere(
        (value) => value.name == typeName,
        orElse: () => HostEventType.error,
      );
      onEvent?.call(
        HostEvent(
          type: type,
          fileName: raw['fileName'] as String? ?? '',
          fileBytes: (raw['fileBytes'] as num?)?.toInt() ?? 0,
          fileSize: (raw['fileSize'] as num?)?.toInt() ?? 0,
          sessionBytes: (raw['sessionBytes'] as num?)?.toInt() ?? 0,
          sessionTotal: (raw['sessionTotal'] as num?)?.toInt() ?? 0,
          message: raw['message'] as String? ?? '',
        ),
      );
    });
  }

  @override
  void Function(HostEvent event)? onEvent;

  @override
  Future<List<ShareFile>> pickFiles() async {
    final rawFiles =
        await _channel.invokeListMethod<Object?>('pickFiles') ?? [];
    return rawFiles
        .map((raw) {
          final map = Map<Object?, Object?>.from(raw as Map);
          return ShareFile(
            id: map['id'] as String,
            name: map['name'] as String,
            size: (map['size'] as num).toInt(),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<Uint8List> readFileRange(
    ShareFile file, {
    required int offset,
    required int length,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readFileRange', {
      'id': file.id,
      'offset': offset,
      'length': length,
    });
    if (bytes == null) throw StateError('Android 文件读取没有返回数据');
    return bytes;
  }

  @override
  Future<List<NetworkNeighbor>> listNeighbors(String localAddress) =>
      _readNeighbors(_channel, localAddress);

  @override
  Future<HostingSession> start({
    required List<ShareFile> files,
    required String advertisedAddress,
    required int preferredPort,
  }) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'startServer',
      {
        'files': files
            .map(
              (file) => {'id': file.id, 'name': file.name, 'size': file.size},
            )
            .toList(growable: false),
        'address': advertisedAddress,
        'port': preferredPort,
      },
    );
    if (raw == null) throw StateError('Android 文件服务没有返回结果');
    return HostingSession(
      urls: (raw['urls'] as List).cast<String>(),
      port: (raw['port'] as num).toInt(),
      totalBytes: (raw['totalBytes'] as num).toInt(),
      usedFallbackPort: raw['usedFallbackPort'] as bool? ?? false,
    );
  }

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stopServer');
}

Future<List<NetworkNeighbor>> _readNeighbors(
  MethodChannel channel,
  String localAddress,
) async {
  final rawItems =
      await channel.invokeListMethod<Object?>('listNeighbors', {
        'localAddress': localAddress,
      }) ??
      [];
  return rawItems
      .map((raw) {
        final map = Map<Object?, Object?>.from(raw as Map);
        return NetworkNeighbor(
          ip: map['ip'] as String,
          mac: map['mac'] as String,
          isReachableCandidate: map['candidate'] as bool? ?? false,
        );
      })
      .toList(growable: false);
}
