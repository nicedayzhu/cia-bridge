import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum FbiClientStage { connecting, urlsSent, acknowledged, cancelled, failed }

class FbiProtocolClient {
  Socket? _socket;
  bool _cancelled = false;

  Future<void> send({
    required String host,
    required int port,
    required List<String> urls,
    required void Function(FbiClientStage stage, Object? error) onStage,
  }) async {
    if (host.trim().isEmpty) throw ArgumentError('3DS IP 不能为空');
    if (port < 1 || port > 65535) throw ArgumentError('接收端口无效');
    if (urls.isEmpty) throw ArgumentError('没有可发送的 URL');

    _cancelled = false;
    onStage(FbiClientStage.connecting, null);
    try {
      final socket = await Socket.connect(
        host.trim(),
        port,
        timeout: const Duration(seconds: 7),
      );
      _socket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);

      final payload = ascii.encode(urls.join('\n'));
      final length = ByteData(4)..setUint32(0, payload.length, Endian.big);
      socket.add(length.buffer.asUint8List());
      socket.add(payload);
      await socket.flush();
      onStage(FbiClientStage.urlsSent, null);

      final ack = await socket.first.timeout(const Duration(hours: 3));
      if (_cancelled) {
        onStage(FbiClientStage.cancelled, null);
      } else if (ack.isNotEmpty && ack.first == 0) {
        onStage(FbiClientStage.acknowledged, null);
      } else if (ack.isNotEmpty) {
        throw const SocketException('3DS 报告请求处理失败');
      } else {
        throw const SocketException('3DS 接收端未返回确认字节');
      }
    } catch (error) {
      if (_cancelled) {
        onStage(FbiClientStage.cancelled, null);
      } else {
        onStage(FbiClientStage.failed, error);
        rethrow;
      }
    } finally {
      await _socket?.close();
      _socket = null;
    }
  }

  void cancel() {
    _cancelled = true;
    _socket?.destroy();
    _socket = null;
  }
}
