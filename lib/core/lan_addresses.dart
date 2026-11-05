import 'dart:io';

Future<List<String>> findLanIpv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final candidates = <String, int>{};
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (!address.isLoopback && !address.isLinkLocal) {
        final ip = address.address;
        final score = _score(ip, interface.name);
        final previous = candidates[ip];
        if (previous == null || score > previous) candidates[ip] = score;
      }
    }
  }
  final result = candidates.keys.toList();
  result.sort((a, b) {
    final scoreCompare = candidates[b]!.compareTo(candidates[a]!);
    return scoreCompare != 0 ? scoreCompare : a.compareTo(b);
  });
  return result;
}

int _score(String ip, String interfaceName) {
  var score = 0;
  if (ip.startsWith('192.168.')) {
    score += 40;
  } else if (ip.startsWith('10.')) {
    score += 30;
  }
  final parts = ip.split('.');
  if (parts.length == 4 && parts.first == '172') {
    final second = int.tryParse(parts[1]);
    if (second != null && second >= 16 && second <= 31) score += 20;
  }
  final name = interfaceName.toLowerCase();
  if (name.contains('wi-fi') ||
      name.contains('wifi') ||
      name.contains('wlan') ||
      name.contains('wireless')) {
    score += 100;
  } else if (name.contains('ethernet') || name.contains('以太网')) {
    score += 80;
  }
  const virtualNames = [
    'vmware',
    'virtualbox',
    'hyper-v',
    'vethernet',
    'wsl',
    'tailscale',
    'zerotier',
    'vpn',
    'tun',
    'tap',
  ];
  if (virtualNames.any(name.contains)) score -= 200;
  return score;
}
