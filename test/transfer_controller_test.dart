import 'dart:async';

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
    expect(controller.discoveryStatus, contains('对照 FBI'));
    expect(controller.selectedDevice, candidate);
    expect(controller.targetIp, candidate.ip);
    controller.dispose();
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
    expect(controller.status, contains('已准备 1 个文件'));
    expect(notifications, greaterThan(0));
    controller.dispose();
  });
}

class _FakeBridge implements FileHostBridge {
  _FakeBridge(this.pickedFiles);

  final List<ShareFile> pickedFiles;

  @override
  void Function(HostEvent event)? onEvent;

  @override
  Future<List<ShareFile>> pickFiles() async => pickedFiles;

  @override
  Future<List<NetworkNeighbor>> listNeighbors(String localAddress) async =>
      const [];

  @override
  Future<HostingSession> start({
    required List<ShareFile> files,
    required String advertisedAddress,
    required int preferredPort,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> stop() async {}
}
