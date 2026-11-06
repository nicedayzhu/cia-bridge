enum TransferMode { qr, push }

enum TransferPhase {
  idle,
  preparing,
  hosting,
  connecting,
  waitingForFbi,
  transferring,
  complete,
  error,
}

class ShareFile {
  const ShareFile({
    required this.id,
    required this.name,
    required this.size,
    this.path,
  });

  final String id;
  final String name;
  final int size;
  final String? path;

  bool get isSupported {
    final lower = name.toLowerCase();
    return lower.endsWith('.cia') ||
        lower.endsWith('.tik') ||
        lower.endsWith('.cetk') ||
        lower.endsWith('.3dsx');
  }
}

class NetworkNeighbor {
  const NetworkNeighbor({
    required this.ip,
    required this.mac,
    this.isReachableCandidate = false,
  });

  final String ip;
  final String mac;
  final bool isReachableCandidate;
}

class NearbyDevice {
  const NearbyDevice({
    required this.ip,
    required this.mac,
    this.port = 5000,
    this.isManual = false,
    this.isCandidate = false,
    this.isProtocolDiscovered = false,
  });

  final String ip;
  final String mac;
  final int port;
  final bool isManual;
  final bool isCandidate;
  final bool isProtocolDiscovered;

  String get name {
    if (isManual) return '手动添加的 3DS';
    if (isProtocolDiscovered) return 'FBI 接收模式';
    if (isCandidate) return '可能的 Nintendo 3DS';
    return 'Nintendo 3DS';
  }
}

class HostingSession {
  const HostingSession({
    required this.urls,
    required this.port,
    required this.totalBytes,
    required this.usedFallbackPort,
  });

  final List<String> urls;
  final int port;
  final int totalBytes;
  final bool usedFallbackPort;

  String get payload => urls.join('\n');
}

enum HostEventType {
  downloadStarted,
  progress,
  downloadFinished,
  error,
  stopped,
}

class HostEvent {
  const HostEvent({
    required this.type,
    this.fileName = '',
    this.fileBytes = 0,
    this.fileSize = 0,
    this.sessionBytes = 0,
    this.sessionTotal = 0,
    this.message = '',
  });

  final HostEventType type;
  final String fileName;
  final int fileBytes;
  final int fileSize;
  final int sessionBytes;
  final int sessionTotal;
  final String message;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  const units = ['KB', 'MB', 'GB', 'TB'];
  var unit = -1;
  do {
    value /= 1024;
    unit++;
  } while (value >= 1024 && unit < units.length - 1);
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
