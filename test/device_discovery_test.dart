import 'package:cia_bridge/core/device_discovery.dart';
import 'package:cia_bridge/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a versioned FBI discovery reply from the same subnet', () {
    final device = parseFbiDiscoveryResponse(
      payload: 'CIA_BRIDGE_FBI_V1;tcp=5000',
      sourceIp: '192.168.0.103',
      localAddress: '192.168.0.104',
    );

    expect(device, isNotNull);
    expect(device!.ip, '192.168.0.103');
    expect(device.port, 5000);
    expect(device.isProtocolDiscovered, isTrue);
  });

  test('parses the patch receiver V2 ports and capabilities', () {
    final device = parseFbiDiscoveryResponse(
      payload:
          'CIA_BRIDGE_FBI_V2;cia=5000;patch=5002;codecs=raw;'
          'features=title-root,zlib;version=2.7.6',
      sourceIp: '192.168.0.103',
      localAddress: '192.168.0.104',
    );

    expect(device, isNotNull);
    expect(device!.port, 5000);
    expect(device.patchPort, 5002);
    expect(device.supportsPatch, isTrue);
    expect(device.receiverVersion, '2.7.6');
    expect(device.supportsPatchTitleRoot, isTrue);
    expect(device.supportsPatchZlib, isTrue);
  });

  test('rejects malformed, local, and cross-subnet discovery replies', () {
    NearbyDevice? parse(String payload, String sourceIp) {
      return parseFbiDiscoveryResponse(
        payload: payload,
        sourceIp: sourceIp,
        localAddress: '192.168.0.104',
      );
    }

    expect(parse('CIA_BRIDGE_FBI_V1;tcp=0', '192.168.0.103'), isNull);
    expect(parse('CIA_BRIDGE_FBI_V2;tcp=5000', '192.168.0.103'), isNull);
    expect(
      parse(
        'CIA_BRIDGE_FBI_V2;cia=5000;patch=5002;codecs=raw,zlib',
        '192.168.0.103',
      ),
      isNull,
    );
    expect(parse('CIA_BRIDGE_FBI_V1;tcp=5000\n', '192.168.0.103'), isNull);
    expect(parse('CIA_BRIDGE_FBI_V1;tcp=5000', '192.168.0.104'), isNull);
    expect(parse('CIA_BRIDGE_FBI_V1;tcp=5000', '192.168.1.103'), isNull);
  });

  test('prefers an exact protocol reply without scanning neighbors', () async {
    var neighborScanCalled = false;
    const receiver = NearbyDevice(
      ip: '192.168.0.103',
      mac: '',
      isProtocolDiscovered: true,
    );
    final discovery = DeviceDiscovery((_) async {
      neighborScanCalled = true;
      return const [];
    }, protocolScanner: (_) async => const [receiver]);

    expect(await discovery.scan('192.168.0.104'), const [receiver]);
    expect(neighborScanCalled, isFalse);
  });

  test(
    'upgrades a Windows ARP result with targeted protocol discovery',
    () async {
      final targetedAddresses = <String>[];
      final discovery = DeviceDiscovery(
        (_) async => const [
          NetworkNeighbor(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01'),
        ],
        protocolScanner: (_) async => const [],
        targetedProtocolScanner: (localAddress, addresses) async {
          expect(localAddress, '192.168.0.104');
          targetedAddresses.addAll(addresses);
          return const [
            NearbyDevice(
              ip: '192.168.0.103',
              mac: '',
              port: 5000,
              patchPort: 5002,
              isProtocolDiscovered: true,
            ),
          ];
        },
      );

      final devices = await discovery.scan('192.168.0.104');

      expect(targetedAddresses, ['192.168.0.103']);
      expect(devices, hasLength(1));
      expect(devices.single.isProtocolDiscovered, isTrue);
      expect(devices.single.supportsPatch, isTrue);
    },
  );

  test(
    'keeps neighbor results when targeted discovery gets no reply',
    () async {
      const neighbor = NetworkNeighbor(
        ip: '192.168.0.103',
        mac: '40:D2:8A:00:00:01',
      );
      final discovery = DeviceDiscovery(
        (_) async => const [neighbor],
        protocolScanner: (_) async => const [],
        targetedProtocolScanner: (_, _) async => const [],
      );

      final devices = await discovery.scan('192.168.0.104');

      expect(devices, hasLength(1));
      expect(devices.single.ip, neighbor.ip);
      expect(devices.single.isProtocolDiscovered, isFalse);
    },
  );

  test(
    'does not drop ready state after one transient missed refresh',
    () async {
      var broadcastScans = 0;
      final discovery = DeviceDiscovery(
        (_) async => const [
          NetworkNeighbor(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01'),
        ],
        protocolScanner: (_) async {
          broadcastScans++;
          return broadcastScans == 1
              ? const [
                  NearbyDevice(
                    ip: '192.168.0.103',
                    mac: '',
                    patchPort: 5002,
                    isProtocolDiscovered: true,
                  ),
                ]
              : const [];
        },
        targetedProtocolScanner: (_, _) async => const [],
      );

      expect(
        (await discovery.scan('192.168.0.104')).single.isProtocolDiscovered,
        isTrue,
      );
      expect(
        (await discovery.scan('192.168.0.104')).single.isProtocolDiscovered,
        isTrue,
      );
      expect(
        (await discovery.scan('192.168.0.104')).single.isProtocolDiscovered,
        isTrue,
      );
      expect(
        (await discovery.scan('192.168.0.104')).single.isProtocolDiscovered,
        isFalse,
      );
    },
  );

  test('protocol results take precedence while other devices remain', () {
    final devices = mergeDiscoveredDevices(
      const [
        NearbyDevice(ip: '192.168.0.8', mac: '40:D2:8A:00:00:08'),
        NearbyDevice(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01'),
      ],
      const [
        NearbyDevice(
          ip: '192.168.0.103',
          mac: '',
          patchPort: 5002,
          isProtocolDiscovered: true,
        ),
      ],
    );

    expect(devices.map((device) => device.ip), [
      '192.168.0.8',
      '192.168.0.103',
    ]);
    expect(devices.last.isProtocolDiscovered, isTrue);
  });

  test('recognizes Nintendo OUIs in common MAC address formats', () {
    expect(isNintendoMac('E8:4E:CE:12:34:56'), isTrue);
    expect(isNintendoMac('00-1F-32-AA-BB-CC'), isTrue);
    expect(isNintendoMac('a4c0e1000001'), isTrue);
  });

  test('does not classify unrelated devices as Nintendo hardware', () {
    expect(isNintendoMac('00:11:22:33:44:55'), isFalse);
    expect(isNintendoMac('not-a-mac'), isFalse);
  });

  test('prefers a verified Nintendo device over reachable candidates', () {
    final devices = devicesFromNeighbors('192.168.0.104', const [
      NetworkNeighbor(ip: '192.168.0.1', mac: '', isReachableCandidate: true),
      NetworkNeighbor(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01'),
    ]);

    expect(devices, hasLength(1));
    expect(devices.single.ip, '192.168.0.103');
    expect(devices.single.isCandidate, isFalse);
  });

  test(
    'returns safe reachable candidates when Android hides MAC addresses',
    () {
      final devices = devicesFromNeighbors('192.168.0.104', const [
        NetworkNeighbor(
          ip: '192.168.0.103',
          mac: '',
          isReachableCandidate: true,
        ),
        NetworkNeighbor(ip: '192.168.0.50', mac: '00:11:22:33:44:55'),
      ]);

      expect(devices, hasLength(1));
      expect(devices.single.ip, '192.168.0.103');
      expect(devices.single.isCandidate, isTrue);
    },
  );

  test('filters the local and other subnets, then sorts by host number', () {
    final devices = devicesFromNeighbors('192.168.0.104', const [
      NetworkNeighbor(ip: '192.168.0.200', mac: '', isReachableCandidate: true),
      NetworkNeighbor(ip: '192.168.1.2', mac: '', isReachableCandidate: true),
      NetworkNeighbor(ip: '192.168.0.104', mac: '', isReachableCandidate: true),
      NetworkNeighbor(ip: '192.168.0.8', mac: '', isReachableCandidate: true),
    ]);

    expect(devices.map((device) => device.ip), [
      '192.168.0.8',
      '192.168.0.200',
    ]);
  });
}
