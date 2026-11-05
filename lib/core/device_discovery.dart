import 'dart:async';
import 'dart:io';

import 'models.dart';

class DeviceDiscovery {
  DeviceDiscovery(this._listNeighbors);

  final Future<List<NetworkNeighbor>> Function(String localAddress)
  _listNeighbors;

  Future<List<NearbyDevice>> scan(String localAddress) async {
    final octets = localAddress.split('.');
    if (octets.length != 4) return const [];
    final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';

    await _warmNeighborCache(prefix, localAddress);
    final neighbors = await _listNeighbors(localAddress);
    return devicesFromNeighbors(localAddress, neighbors);
  }

  Future<void> _warmNeighborCache(String prefix, String localAddress) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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

bool isNintendoMac(String mac) {
  final normalized = mac.replaceAll(RegExp('[^0-9A-Fa-f]'), '').toUpperCase();
  return normalized.length >= 6 &&
      nintendoOuiPrefixes.contains(normalized.substring(0, 6));
}

int _lastOctet(String address) => int.tryParse(address.split('.').last) ?? 0;

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
