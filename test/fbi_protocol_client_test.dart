import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cia_bridge/core/fbi_protocol_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'sends a big-endian length, newline-separated URLs, and accepts ack',
    () async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<String>();
      final serverDone = Completer<void>();
      listener.listen((socket) {
        final bytes = <int>[];
        socket.listen((chunk) async {
          bytes.addAll(chunk);
          if (bytes.length < 4) return;
          final length = ByteData.sublistView(
            Uint8List.fromList(bytes),
            0,
            4,
          ).getUint32(0, Endian.big);
          if (bytes.length < 4 + length || received.isCompleted) return;
          received.complete(ascii.decode(bytes.sublist(4, 4 + length)));
          socket.add(const [0]);
          await socket.flush();
          await socket.close();
          if (!serverDone.isCompleted) serverDone.complete();
        });
      });

      final stages = <FbiClientStage>[];
      final client = FbiProtocolClient();
      await client.send(
        host: '127.0.0.1',
        port: listener.port,
        urls: const [
          'http://192.168.1.2:8080/a.cia',
          'http://192.168.1.2:8080/b.cia',
        ],
        onStage: (stage, _) => stages.add(stage),
      );

      expect(
        await received.future,
        'http://192.168.1.2:8080/a.cia\nhttp://192.168.1.2:8080/b.cia',
      );
      expect(
        stages,
        containsAllInOrder([
          FbiClientStage.connecting,
          FbiClientStage.urlsSent,
          FbiClientStage.acknowledged,
        ]),
      );
      await serverDone.future;
      await listener.close();
    },
  );
}
