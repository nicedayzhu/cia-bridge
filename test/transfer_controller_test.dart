import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cia_bridge/core/models.dart';
import 'package:cia_bridge/platform/file_host_bridge.dart';
import 'package:cia_bridge/transfer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps a device selected while an older empty scan completes', () async {
    final scanResult = Completer<List<NearbyDevice>>();
    final controller =
        TransferController(deviceScanner: (_) => scanResult.future)
          ..addresses = ['192.168.0.104']
          ..selectedAddress = '192.168.0.104';
    const device = NearbyDevice(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01');

    final scan = controller.refreshDevices();
    controller.selectDevice(device);
    scanResult.complete(const []);
    await scan;

    expect(controller.selectedDevice, device);
    expect(controller.targetIp, device.ip);
    controller.dispose();
  });

  test('describes reachable Android candidates and allows selection', () async {
    const candidate = NearbyDevice(
      ip: '192.168.0.103',
      mac: '',
      isCandidate: true,
    );
    final controller =
        TransferController(deviceScanner: (_) async => const [candidate])
          ..addresses = ['192.168.0.104']
          ..selectedAddress = '192.168.0.104';

    await controller.refreshDevices();
    controller.selectDevice(candidate);

    expect(controller.discoveryStatus, contains('在线候选'));
    expect(controller.discoveryStatus, contains('对照 3DS'));
    expect(controller.selectedDevice, candidate);
    expect(controller.targetIp, candidate.ip);
    controller.dispose();
  });

  test('uses the port advertised by an exact FBI discovery reply', () async {
    const receiver = NearbyDevice(
      ip: '192.168.0.103',
      mac: '',
      port: 5123,
      isProtocolDiscovered: true,
    );
    final controller =
        TransferController(deviceScanner: (_) async => const [receiver])
          ..addresses = ['192.168.0.104']
          ..selectedAddress = '192.168.0.104';

    await controller.refreshDevices();
    controller.selectDevice(receiver);

    expect(controller.discoveryStatus, contains('正在等待接收'));
    expect(controller.targetIp, receiver.ip);
    expect(controller.targetPort, 5123);
    controller.dispose();
  });

  test('manual device can advertise separate CIA and patch ports', () {
    final controller = TransferController();

    controller.addManualDevice('192.168.0.103', port: 5000, patchPort: 5002);

    expect(controller.selectedDevice?.isManual, isTrue);
    expect(controller.selectedDevice?.port, 5000);
    expect(controller.selectedDevice?.patchPort, 5002);
    expect(controller.selectedDevice?.supportsPatch, isTrue);
    expect(controller.targetPort, 5000);
    expect(controller.status, contains('LayeredFS 补丁'));
    controller.dispose();
  });

  test('manual device rejects an invalid patch port', () {
    final controller = TransferController();

    expect(
      () => controller.addManualDevice(
        '192.168.0.103',
        port: 5000,
        patchPort: 70000,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('补丁端口'),
        ),
      ),
    );
    controller.dispose();
  });

  test('switches between the advertised patch and CIA ports', () async {
    final root = await Directory.systemTemp.createTemp('controller_patch_');
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'luma/titles/0004000000194200/romfs/file.bin',
          'patch',
        ),
      );
    final zip = File('${root.path}${Platform.pathSeparator}corpse-party.zip');
    await zip.writeAsBytes(ZipEncoder().encode(archive));
    final bridge = _FakeBridge([
      ShareFile(
        id: zip.path,
        name: 'corpse-party.zip',
        size: await zip.length(),
        path: zip.path,
      ),
    ]);
    const receiver = NearbyDevice(
      ip: '192.168.0.103',
      mac: '',
      port: 5000,
      patchPort: 5002,
      isProtocolDiscovered: true,
    );
    final controller = TransferController(bridge: bridge)
      ..selectedDevice = receiver;
    try {
      await controller.pickFiles();
      expect(controller.isPatchMode, isTrue);
      expect(controller.targetPort, 5002);

      controller.clearFiles();
      expect(controller.isPatchMode, isFalse);
      expect(controller.targetPort, 5000);
    } finally {
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test(
    'rejects a patch ZIP when the selected FBI has no patch capability',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'controller_stock_fbi_',
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'luma/titles/0004000000194200/romfs/file.bin',
            'patch',
          ),
        );
      final zip = File('${root.path}${Platform.pathSeparator}patch.zip');
      await zip.writeAsBytes(ZipEncoder().encode(archive));
      final bridge = _FakeBridge([
        ShareFile(
          id: zip.path,
          name: 'patch.zip',
          size: await zip.length(),
          path: zip.path,
        ),
      ]);
      const stockFbi = NearbyDevice(
        ip: '192.168.0.103',
        mac: '40:D2:8A:00:00:01',
      );
      final controller = TransferController(bridge: bridge)
        ..selectDevice(stockFbi);
      try {
        await expectLater(
          controller.pickFiles(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('仅能使用 CIA 安装服务'),
            ),
          ),
        );
        expect(controller.isPatchMode, isFalse);
        expect(controller.targetPort, 5000);
      } finally {
        controller.dispose();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
  );

  test('rejects mixing a patch ZIP with installation files', () async {
    final root = await Directory.systemTemp.createTemp('controller_mixed_');
    final zip = File('${root.path}${Platform.pathSeparator}patch.zip');
    await zip.writeAsBytes(const [0]);
    final bridge = _FakeBridge([
      ShareFile(
        id: zip.path,
        name: 'patch.zip',
        size: await zip.length(),
        path: zip.path,
        deleteLocalPath: true,
      ),
      const ShareFile(
        id: r'D:\Games\game.cia',
        name: 'game.cia',
        size: 1024,
        path: r'D:\Games\game.cia',
      ),
    ]);
    final controller = TransferController(bridge: bridge);
    try {
      await expectLater(controller.pickFiles(), throwsFormatException);
      expect(controller.files, isEmpty);
      expect(controller.isPatchMode, isFalse);
      expect(await zip.exists(), isFalse);
    } finally {
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    }
  });

  test('discards an old scan after the local address changes', () async {
    final firstScan = Completer<List<NearbyDevice>>();
    final secondScan = Completer<List<NearbyDevice>>();
    final controller =
        TransferController(
            deviceScanner: (address) => address == '192.168.0.104'
                ? firstScan.future
                : secondScan.future,
          )
          ..addresses = ['192.168.0.104', '192.168.1.20']
          ..selectedAddress = '192.168.0.104';

    final oldRefresh = controller.refreshDevices();
    controller.setAddress('192.168.1.20');
    firstScan.complete(const [
      NearbyDevice(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01'),
    ]);
    await oldRefresh;
    await Future<void>.delayed(Duration.zero);
    secondScan.complete(const [
      NearbyDevice(ip: '192.168.1.19', mac: '40:D2:8A:00:00:02'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(controller.devices.single.ip, '192.168.1.19');
    controller.dispose();
  });

  test('retries an initially empty local address lookup', () async {
    var calls = 0;
    final controller = TransferController(
      addressFinder: () async {
        calls++;
        return calls == 1 ? const [] : const ['192.168.0.104'];
      },
    );

    await controller.refreshAddresses();

    expect(calls, 2);
    expect(controller.addresses, ['192.168.0.104']);
    expect(controller.selectedAddress, '192.168.0.104');
    controller.dispose();
  });

  test('keeps the previous address after a transient lookup failure', () async {
    final controller =
        TransferController(
            addressFinder: () => Future<List<String>>.error(
              const FormatException('temporary failure'),
            ),
          )
          ..addresses = ['192.168.0.104']
          ..selectedAddress = '192.168.0.104';

    await controller.refreshAddresses();

    expect(controller.addresses, ['192.168.0.104']);
    expect(controller.selectedAddress, '192.168.0.104');
    expect(controller.addressStatus, contains('失败'));
    controller.dispose();
  });

  test('adds a selected CIA file and notifies the UI', () async {
    final bridge = _FakeBridge(const [
      ShareFile(
        id: r'D:\Games\3DShell.cia',
        name: '3DShell.cia',
        size: 1600000,
        path: r'D:\Games\3DShell.cia',
      ),
    ]);
    final controller = TransferController(bridge: bridge);
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.pickFiles();

    expect(controller.files, hasLength(1));
    expect(controller.files.single.name, '3DShell.cia');
    expect(controller.files.single.metadataState, CiaMetadataState.unavailable);
    expect(controller.status, contains('已准备 1 个文件'));
    expect(notifications, greaterThan(0));
    controller.dispose();
  });

  test(
    'calculates a smoothed speed and a ticking ETA from host events',
    () async {
      var now = DateTime(2026, 11, 7, 12);
      const file = ShareFile(
        id: 'test-cia',
        name: 'test.cia',
        size: 20 * 1024 * 1024,
      );
      final bridge = _FakeBridge(const [file]);
      final controller = TransferController(bridge: bridge, now: () => now)
        ..files.add(file)
        ..selectedAddress = '192.168.0.104';

      await controller.startQr();
      bridge.onEvent?.call(
        const HostEvent(
          type: HostEventType.downloadStarted,
          fileName: 'test.cia',
          fileSize: 20 * 1024 * 1024,
          sessionTotal: 20 * 1024 * 1024,
        ),
      );
      now = now.add(const Duration(seconds: 1));
      bridge.onEvent?.call(
        const HostEvent(
          type: HostEventType.progress,
          fileName: 'test.cia',
          fileBytes: 4 * 1024 * 1024,
          fileSize: 20 * 1024 * 1024,
          sessionBytes: 4 * 1024 * 1024,
          sessionTotal: 20 * 1024 * 1024,
        ),
      );
      now = now.add(const Duration(seconds: 1));
      bridge.onEvent?.call(
        const HostEvent(
          type: HostEventType.progress,
          fileName: 'test.cia',
          fileBytes: 8 * 1024 * 1024,
          fileSize: 20 * 1024 * 1024,
          sessionBytes: 8 * 1024 * 1024,
          sessionTotal: 20 * 1024 * 1024,
        ),
      );

      expect(controller.transferActive, isTrue);
      expect(controller.transferBytesPerSecond, closeTo(4 * 1024 * 1024, 1));
      expect(controller.estimatedRemaining, const Duration(seconds: 3));

      now = now.add(const Duration(seconds: 1));
      expect(controller.estimatedRemaining, const Duration(seconds: 2));

      bridge.onEvent?.call(
        const HostEvent(
          type: HostEventType.downloadFinished,
          fileName: 'test.cia',
          fileSize: 20 * 1024 * 1024,
          sessionBytes: 20 * 1024 * 1024,
          sessionTotal: 20 * 1024 * 1024,
        ),
      );
      expect(controller.transferActive, isFalse);
      expect(controller.estimatedRemaining, isNull);
      controller.dispose();
    },
  );
}

class _FakeBridge implements FileHostBridge {
  _FakeBridge(this.pickedFiles);

  final List<ShareFile> pickedFiles;

  @override
  void Function(HostEvent event)? onEvent;

  @override
  Future<List<ShareFile>> pickFiles() async => pickedFiles;

  @override
  Future<String> dataDirectory() async => Directory.systemTemp.path;

  @override
  Future<Uint8List> readFileRange(
    ShareFile file, {
    required int offset,
    required int length,
  }) => Future<Uint8List>.error(
    UnsupportedError('Test bridge does not expose file bytes'),
  );

  @override
  Future<List<NetworkNeighbor>> listNeighbors(String localAddress) async =>
      const [];

  @override
  Future<HostingSession> start({
    required List<ShareFile> files,
    required String advertisedAddress,
    required int preferredPort,
  }) async => HostingSession(
    urls: files
        .map((file) => 'http://$advertisedAddress:$preferredPort/${file.name}')
        .toList(growable: false),
    port: preferredPort,
    totalBytes: files.fold(0, (total, file) => total + file.size),
    usedFallbackPort: false,
  );

  @override
  Future<void> stop() async {}
}
