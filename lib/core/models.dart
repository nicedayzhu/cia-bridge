import 'dart:typed_data';

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

enum CiaMetadataState { notApplicable, loading, available, unavailable }

enum CiaTitleKind {
  application,
  demo,
  update,
  downloadableContent,
  dsiWare,
  system,
  unknown,
}

extension CiaTitleKindLabel on CiaTitleKind {
  String get label => switch (this) {
    CiaTitleKind.application => '游戏 / 应用',
    CiaTitleKind.demo => '试玩版',
    CiaTitleKind.update => '更新数据',
    CiaTitleKind.downloadableContent => 'DLC',
    CiaTitleKind.dsiWare => 'DSiWare',
    CiaTitleKind.system => '系统内容',
    CiaTitleKind.unknown => '未知类型',
  };
}

class CiaMetadata {
  const CiaMetadata({
    required this.titleId,
    required this.titleVersion,
    required this.kind,
    this.shortTitle,
    this.longTitle,
    this.publisher,
    this.regionMask,
    this.smdhFlags,
    this.iconPng,
    this.metaReadError,
  });

  final String titleId;
  final int titleVersion;
  final CiaTitleKind kind;
  final String? shortTitle;
  final String? longTitle;
  final String? publisher;
  final int? regionMask;
  final int? smdhFlags;
  final Uint8List? iconPng;
  final String? metaReadError;

  String? get displayTitle {
    final short = shortTitle?.trim();
    if (short != null && short.isNotEmpty) return short;
    final long = longTitle?.trim();
    return long != null && long.isNotEmpty ? long : null;
  }

  String get versionLabel {
    final major = (titleVersion >> 10) & 0x3f;
    final minor = (titleVersion >> 4) & 0x3f;
    final micro = titleVersion & 0x0f;
    return 'v$major.$minor.$micro';
  }

  String get regionLabel {
    final mask = regionMask;
    if (mask == null || mask == 0) return '地区未知';
    if (mask == 0x7fffffff || mask == 0xffffffff) return '全区';
    const regions = [
      (0x01, '日'),
      (0x02, '美'),
      (0x04, '欧'),
      (0x08, '澳'),
      (0x10, '中'),
      (0x20, '韩'),
      (0x40, '台'),
    ];
    final labels = [
      for (final region in regions)
        if ((mask & region.$1) != 0) region.$2,
    ];
    return labels.isEmpty ? '地区未知' : labels.join('/');
  }

  bool get isNew3dsOnly => (smdhFlags ?? 0) & 0x1000 != 0;
  bool get hasSmdh =>
      shortTitle != null || longTitle != null || iconPng != null;
}

class ShareFile {
  const ShareFile({
    required this.id,
    required this.name,
    required this.size,
    this.path,
    this.deleteLocalPath = false,
    this.ciaMetadata,
    this.metadataState = CiaMetadataState.notApplicable,
    this.metadataError,
  });

  final String id;
  final String name;
  final int size;
  final String? path;
  final bool deleteLocalPath;
  final CiaMetadata? ciaMetadata;
  final CiaMetadataState metadataState;
  final String? metadataError;

  bool get isCia => name.toLowerCase().endsWith('.cia');
  bool get isZip => name.toLowerCase().endsWith('.zip');

  String get displayName => ciaMetadata?.displayTitle ?? name;

  bool get isSupported {
    final lower = name.toLowerCase();
    return lower.endsWith('.cia') ||
        lower.endsWith('.tik') ||
        lower.endsWith('.cetk') ||
        lower.endsWith('.3dsx') ||
        lower.endsWith('.zip');
  }

  ShareFile withCiaMetadata({
    required CiaMetadataState state,
    CiaMetadata? metadata,
    String? error,
  }) => ShareFile(
    id: id,
    name: name,
    size: size,
    path: path,
    deleteLocalPath: deleteLocalPath,
    ciaMetadata: metadata,
    metadataState: state,
    metadataError: error,
  );
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
    this.patchPort,
    this.isManual = false,
    this.isCandidate = false,
    this.isProtocolDiscovered = false,
  });

  final String ip;
  final String mac;
  final int port;
  final int? patchPort;
  final bool isManual;
  final bool isCandidate;
  final bool isProtocolDiscovered;

  bool get supportsPatch => patchPort != null;

  String get name {
    if (isManual) return '手动添加的 Nintendo 3DS';
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
