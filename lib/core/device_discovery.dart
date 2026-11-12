import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

const fbiDiscoveryPort = 5001;
const fbiDiscoveryRequest = 'CIA_BRIDGE_DISCOVER_V1';
const fbiDiscoveryResponsePrefix = 'CIA_BRIDGE_FBI_V1;tcp=';
const fbiDiscoveryV2Prefix = 'CIA_BRIDGE_FBI_V2;';
const patchFeatureTitleRoot = 'title-root';
const patchFeatureZlib = 'zlib';

class DeviceDiscovery {
  static const _protocolMissGraceScans = 2;

  DeviceDiscovery(
    this._listNeighbors, {
    Future<List<NearbyDevice>> Function(String localAddress)? protocolScanner,
    Future<List<NearbyDevice>> Function(
      String localAddress,
      Iterable<String> targetAddresses,
    )?
    targetedProtocolScanner,
  }) : _protocolScanner = protocolScanner ?? discoverFbiReceivers,
       _targetedProtocolScanner =
           targetedProtocolScanner ??
           (protocolScanner == null
               ? (localAddress, targetAddresses) => discoverFbiReceivers(
                   localAddress,
                   unicastTargets: targetAddresses,
                 )
               : null);

  final Future<List<NetworkNeighbor>> Function(String localAddress)
  _listNeighbors;
  final Future<List<NearbyDevice>> Function(String localAddress)
  _protocolScanner;
  final Future<List<NearbyDevice>> Function(
    String localAddress,
    Iterable<String> targetAddresses,
  )?
  _targetedProtocolScanner;
  final Map<String, NearbyDevice> _recentProtocolDevices = {};
  final Map<String, int> _protocolMisses = {};

  Future<List<NearbyDevice>> scan(String localAddress) async {
    final prefix = _ipv4Prefix(localAddress);
    if (prefix == null) return const [];

    final protocolDevices = await _protocolScanner(localAddress);
    if (protocolDevices.isNotEmpty) {
      _rememberProtocolDevices(protocolDevices);
      return protocolDevices;
    }

    await _warmNeighborCache(prefix, localAddress);
    final neighbors = await _listNeighbors(localAddress);
    final neighborDevices = devicesFromNeighbors(localAddress, neighbors);
    final targetedScanner = _targetedProtocolScanner;
    if (neighborDevices.isEmpty || targetedScanner == null) {
      return _applyProtocolGrace(neighborDevices);
    }

    // Windows can populate its ARP table while dropping or routing broadcasts
    // through another adapter. Confirm the known IPs with unicast discovery so
    // a visible 3DS is upgraded to its real CIA Bridge capabilities.
    final targetedDevices = await targetedScanner(
      localAddress,
      neighborDevices.map((device) => device.ip),
    );
    return _applyProtocolGrace(
      mergeDiscoveredDevices(neighborDevices, targetedDevices),
    );
  }

  void _rememberProtocolDevices(Iterable<NearbyDevice> devices) {
    for (final device in devices) {
      if (!device.isProtocolDiscovered) continue;
      _recentProtocolDevices[device.ip] = device;
      _protocolMisses.remove(device.ip);
    }
  }

  List<NearbyDevice> _applyProtocolGrace(List<NearbyDevice> devices) {
    final visibleAddresses = devices.map((device) => device.ip).toSet();
    _recentProtocolDevices.keys
        .where((address) => !visibleAddresses.contains(address))
        .toList(growable: false)
        .forEach((address) {
          _recentProtocolDevices.remove(address);
          _protocolMisses.remove(address);
        });

    final stabilized = <NearbyDevice>[];
    for (final device in devices) {
      if (device.isProtocolDiscovered) {
        _rememberProtocolDevices([device]);
        stabilized.add(device);
        continue;
      }

      final recent = _recentProtocolDevices[device.ip];
      if (recent == null) {
        stabilized.add(device);
        continue;
      }

      final misses = (_protocolMisses[device.ip] ?? 0) + 1;
      _protocolMisses[device.ip] = misses;
      if (misses <= _protocolMissGraceScans) {
        stabilized.add(recent);
      } else {
        _recentProtocolDevices.remove(device.ip);
        _protocolMisses.remove(device.ip);
        stabilized.add(device);
      }
    }
    return stabilized;
  }

  Future<void> _warmNeighborCache(String prefix, String localAddress) async {
    RawDatagramSocket? socket;
    try {
      socket = await _bindDiscoverySocket(localAddress);
      for (var host = 1; host < 255; host++) {
        final candidate = '$prefix.$host';
        if (candidate == localAddress) continue;
        socket.send(const [0], InternetAddress(candidate), 9);
      }
      await Future<void>.delayed(const Duration(milliseconds: 450));
    } on SocketException {
      // The existing ARP/neighbor cache can still provide useful results.
    } finally {
      socket?.close();
    }
  }
}

Future<List<NearbyDevice>> discoverFbiReceivers(
  String localAddress, {
  Iterable<String> unicastTargets = const [],
}) async {
  final prefix = _ipv4Prefix(localAddress);
  if (prefix == null) return const [];

  RawDatagramSocket? socket;
  StreamSubscription<RawSocketEvent>? subscription;
  final found = <String, NearbyDevice>{};
  try {
    final activeSocket = await _bindDiscoverySocket(localAddress);
    socket = activeSocket;
    activeSocket.broadcastEnabled = true;
    subscription = activeSocket.listen((event) {
      if (event != RawSocketEvent.read) return;
      while (true) {
        final datagram = socket?.receive();
        if (datagram == null) break;
        try {
          final device = parseFbiDiscoveryResponse(
            payload: utf8.decode(datagram.data),
            sourceIp: datagram.address.address,
            localAddress: localAddress,
          );
          if (device != null) found[device.ip] = device;
        } on FormatException {
          // Discovery traffic from unrelated devices is intentionally ignored.
        }
      }
    }, onError: (_) {});

    final request = utf8.encode(fbiDiscoveryRequest);
    final targets = <InternetAddress>[
      InternetAddress('$prefix.255'),
      InternetAddress('255.255.255.255'),
      ...unicastTargets
          .where(
            (target) => target != localAddress && _ipv4Prefix(target) == prefix,
          )
          .toSet()
          .map(InternetAddress.new),
    ];
    for (var attempt = 0; attempt < 3; attempt++) {
      for (final target in targets) {
        try {
          activeSocket.send(request, target, fbiDiscoveryPort);
        } on SocketException {
          // Some platforms reject the global broadcast but allow the directed one.
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 170));
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
  } on SocketException {
    return const [];
  } finally {
    await subscription?.cancel();
    socket?.close();
  }

  final devices = found.values.toList(growable: false);
  devices.sort(
    (left, right) => _lastOctet(left.ip).compareTo(_lastOctet(right.ip)),
  );
  return devices;
}

Future<RawDatagramSocket> _bindDiscoverySocket(String localAddress) async {
  try {
    // Binding the selected address keeps Windows from sending discovery over
    // a VPN, virtual adapter, or a different physical network interface.
    return await RawDatagramSocket.bind(InternetAddress(localAddress), 0);
  } on SocketException {
    // The address can disappear between interface enumeration and scanning.
    // Falling back preserves discovery on platforms that reject a local bind.
    return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }
}

NearbyDevice? parseFbiDiscoveryResponse({
  required String payload,
  required String sourceIp,
  required String localAddress,
}) {
  final localPrefix = _ipv4Prefix(localAddress);
  final sourcePrefix = _ipv4Prefix(sourceIp);
  if (localPrefix == null ||
      sourcePrefix != localPrefix ||
      sourceIp == localAddress ||
      (!payload.startsWith(fbiDiscoveryResponsePrefix) &&
          !payload.startsWith(fbiDiscoveryV2Prefix))) {
    return null;
  }

  if (payload.startsWith(fbiDiscoveryV2Prefix)) {
    final fields = <String, String>{};
    for (final field
        in payload.substring(fbiDiscoveryV2Prefix.length).split(';')) {
      final separator = field.indexOf('=');
      if (separator <= 0) continue;
      fields[field.substring(0, separator)] = field.substring(separator + 1);
    }
    final ciaPort = _validPort(fields['cia']) ?? 5000;
    final patchPort = _validPort(fields['patch']);
    if (patchPort == null || fields['codecs'] != 'raw') return null;
    final features = (fields['features'] ?? '')
        .split(',')
        .where((feature) => feature.isNotEmpty)
        .toSet();
    return NearbyDevice(
      ip: sourceIp,
      mac: '',
      port: ciaPort,
      patchPort: patchPort,
      receiverVersion: _validReceiverVersion(fields['version']),
      supportsPatchTitleRoot: features.contains(patchFeatureTitleRoot),
      supportsPatchZlib: features.contains(patchFeatureZlib),
      isProtocolDiscovered: true,
    );
  }

  final portText = payload.substring(fbiDiscoveryResponsePrefix.length);
  if (!RegExp(r'^\d{1,5}$').hasMatch(portText)) return null;
  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) return null;

  return NearbyDevice(
    ip: sourceIp,
    mac: '',
    port: port,
    isProtocolDiscovered: true,
  );
}

int? _validPort(String? text) {
  if (text == null || !RegExp(r'^\d{1,5}$').hasMatch(text)) return null;
  final value = int.tryParse(text);
  return value != null && value >= 1 && value <= 65535 ? value : null;
}

String? _validReceiverVersion(String? text) {
  if (text == null || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(text)) {
    return null;
  }
  return text;
}

List<NearbyDevice> devicesFromNeighbors(
  String localAddress,
  List<NetworkNeighbor> neighbors,
) {
  final octets = localAddress.split('.');
  if (octets.length != 4) return const [];
  final prefix = '${octets[0]}.${octets[1]}.${octets[2]}.';
  final sameSubnet = neighbors.where(
    (neighbor) => neighbor.ip != localAddress && neighbor.ip.startsWith(prefix),
  );
  final verified = sameSubnet
      .where((neighbor) => isNintendoMac(neighbor.mac))
      .map((neighbor) => NearbyDevice(ip: neighbor.ip, mac: neighbor.mac))
      .toList(growable: false);
  if (verified.isNotEmpty) {
    verified.sort(
      (left, right) => _lastOctet(left.ip).compareTo(_lastOctet(right.ip)),
    );
    return verified;
  }
  final candidates = sameSubnet
      .where((neighbor) => neighbor.isReachableCandidate)
      .map(
        (neighbor) =>
            NearbyDevice(ip: neighbor.ip, mac: neighbor.mac, isCandidate: true),
      )
      .toList(growable: false);
  candidates.sort(
    (left, right) => _lastOctet(left.ip).compareTo(_lastOctet(right.ip)),
  );
  return candidates;
}

List<NearbyDevice> mergeDiscoveredDevices(
  Iterable<NearbyDevice> fallbackDevices,
  Iterable<NearbyDevice> protocolDevices,
) {
  final devicesByIp = <String, NearbyDevice>{
    for (final device in fallbackDevices) device.ip: device,
  };
  for (final device in protocolDevices) {
    if (device.isProtocolDiscovered) devicesByIp[device.ip] = device;
  }
  final devices = devicesByIp.values.toList(growable: false);
  devices.sort(
    (left, right) => _lastOctet(left.ip).compareTo(_lastOctet(right.ip)),
  );
  return devices;
}

bool isNintendoMac(String mac) {
  final normalized = mac.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase();
  return normalized.length >= 6 &&
      nintendoOuiPrefixes.contains(normalized.substring(0, 6));
}

int _lastOctet(String address) => int.tryParse(address.split('.').last) ?? 0;

String? _ipv4Prefix(String address) {
  final octets = address.split('.');
  if (octets.length != 4 ||
      octets.any((part) {
        final value = int.tryParse(part);
        return value == null || value < 0 || value > 255;
      })) {
    return null;
  }
  return '${octets[0]}.${octets[1]}.${octets[2]}';
}

// Nintendo OUIs used by 3DS-family devices. The list follows Boop's discovery
// approach, but the app never connects just to probe TCP/5000: doing so would
// consume FBI's pending connection and show an error on the console.
const nintendoOuiPrefixes = <String>{
  '0009BF',
  '001656',
  '0017AB',
  '00191D',
  '0019FD',
  '001AE9',
  '001B7A',
  '001BEA',
  '001CBE',
  '001DBC',
  '001E35',
  '001EA9',
  '001F32',
  '001FC5',
  '002147',
  '0021BD',
  '00224C',
  '0022AA',
  '0022D7',
  '002331',
  '0023CC',
  '00241E',
  '002444',
  '0024F3',
  '0025A0',
  '002659',
  '002709',
  '0403D6',
  '182A7B',
  '2C10C1',
  '34AF2C',
  '40D28A',
  '40F407',
  '582F40',
  '58BDA3',
  '5C521E',
  '606BFF',
  '64B5C6',
  '78A2A0',
  '7CBB8A',
  '8C56C5',
  '8CCDE8',
  '98B6E9',
  '9CE635',
  'A438CC',
  'A45C27',
  'A4C0E1',
  'B87826',
  'B88AEC',
  'B8AE6E',
  'CC9E00',
  'CCFB65',
  'D86BF7',
  'DC68EB',
  'E00C7F',
  'E0E751',
  'E84ECE',
  'ECC40D',
};
