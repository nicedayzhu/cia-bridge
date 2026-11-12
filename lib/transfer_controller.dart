import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'core/cia_metadata.dart';
import 'core/fbi_protocol_client.dart';
import 'core/device_discovery.dart';
import 'core/lan_addresses.dart';
import 'core/models.dart';
import 'core/patch_bundle.dart';
import 'core/patch_title_info.dart';
import 'platform/file_host_bridge.dart';

class TransferController extends ChangeNotifier {
  TransferController({
    FileHostBridge? bridge,
    CiaMetadataParser? metadataParser,
    PatchBundleBuilder? patchBuilder,
    PatchTitleInfoService? patchTitleInfoService,
    Future<List<String>> Function()? addressFinder,
    Future<List<NearbyDevice>> Function(String address)? deviceScanner,
    DateTime Function()? now,
  }) : _bridge = bridge ?? FileHostBridge(),
       _metadataParser = metadataParser ?? const CiaMetadataParser(),
       _patchBuilder = patchBuilder ?? const PatchBundleBuilder(),
       _patchTitleInfoService =
           patchTitleInfoService ?? PatchTitleInfoService(),
       _addressFinder = addressFinder ?? findLanIpv4Addresses,
       _now = now ?? DateTime.now {
    _bridge.onEvent = _handleHostEvent;
    _scanDevices = deviceScanner ?? DeviceDiscovery(_bridge.listNeighbors).scan;
  }

  final FileHostBridge _bridge;
  final CiaMetadataParser _metadataParser;
  final PatchBundleBuilder _patchBuilder;
  final PatchTitleInfoService _patchTitleInfoService;
  final Future<List<String>> Function() _addressFinder;
  final DateTime Function() _now;
  late final Future<List<NearbyDevice>> Function(String address) _scanDevices;
  final FbiProtocolClient _fbi = FbiProtocolClient();

  final List<ShareFile> files = [];
  PreparedPatch? preparedPatch;
  PatchTitleInfo? patchTitleInfo;
  bool buildingPatch = false;
  List<String> addresses = [];
  List<NearbyDevice> devices = [];
  NearbyDevice? selectedDevice;
  bool scanningAddresses = false;
  bool scanningDevices = false;
  String addressStatus = '正在检测本机局域网地址…';
  String discoveryStatus = '正在查找附近的 3DS…';
  String? selectedAddress;
  int httpPort = 8080;
  String targetIp = '';
  int targetPort = 5000;
  TransferMode mode = TransferMode.qr;
  TransferPhase phase = TransferPhase.idle;
  HostingSession? session;
  String status = '选择安装文件或补丁 ZIP 后即可通过局域网发送';
  int bytesServed = 0;
  int totalBytes = 0;
  bool transferActive = false;
  double transferBytesPerSecond = 0;
  DateTime? estimatedCompletionAt;
  bool serverRunning = false;
  DateTime? _lastProgressAt;
  int _lastProgressBytes = 0;
  int _speedSampleCount = 0;
  int _deviceScanGeneration = 0;
  bool _disposed = false;

  bool get isBusy =>
      phase == TransferPhase.preparing || phase == TransferPhase.connecting;

  double? get progress {
    if (totalBytes <= 0) return null;
    return (bytesServed / totalBytes).clamp(0, 1);
  }

  Duration? get estimatedRemaining {
    final completionAt = estimatedCompletionAt;
    if (!transferActive || completionAt == null) return null;
    final remaining = completionAt.difference(_now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isPatchMode => preparedPatch != null;

  String get patchDisplayName {
    final patch = preparedPatch;
    if (patch == null) return '';
    return patchTitleInfo?.name ?? patch.sourceLabel;
  }

  String get patchInfoLine {
    final patch = preparedPatch;
    if (patch == null) return '';
    final details = patchTitleInfo?.details ?? '';
    return [
      if (details.isNotEmpty) details,
      'Title ID ${patch.titleId}',
    ].join(' · ');
  }

  List<ShareFile> get selectedFiles =>
      preparedPatch == null ? List.unmodifiable(files) : [preparedPatch!.file];

  int get selectedBytes =>
      selectedFiles.fold(0, (total, file) => total + file.size);

  Future<void> initialize() async {
    await refreshAddresses();
    await refreshDevices();
  }

  Future<void> refreshAddresses({bool retryOnEmpty = true}) async {
    if (scanningAddresses) return;
    scanningAddresses = true;
    addressStatus = '正在检测本机局域网地址…';
    _notify();
    final previous = selectedAddress;
    try {
      var found = await _addressFinder();
      if (found.isEmpty && retryOnEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        found = await _addressFinder();
      }
      if (found.isNotEmpty) {
        addresses = found;
        selectedAddress = previous != null && found.contains(previous)
            ? previous
            : found.first;
        addressStatus = '已找到 ${found.length} 个可用地址';
      } else {
        addressStatus = '未找到局域网地址，请确认 Wi-Fi 已连接后重试';
        if (addresses.isEmpty) {
          selectedAddress = null;
          status = '未找到 IPv4 局域网地址，请先连接与 3DS 相同的 Wi‑Fi';
        }
      }
    } catch (_) {
      addressStatus = '检测本机地址失败，请点击重新检测';
      if (addresses.isEmpty) {
        selectedAddress = null;
        status = '无法读取本机 IPv4 地址，请检查网络连接后重试';
      }
    } finally {
      scanningAddresses = false;
      _notify();
    }
  }

  Future<void> pickFiles() async {
    final picked = await _bridge.pickFiles();
    final archives = picked.where((file) => file.isZip).toList(growable: false);
    if (archives.isNotEmpty) {
      if (archives.length != 1 || picked.length != 1) {
        await _deleteTemporarySelections(picked);
        throw const FormatException('补丁 ZIP 不能和安装文件混选，请一次只选择一个补丁 ZIP');
      }
      if (selectedDevice?.supportsPatch != true) {
        await _deleteTemporarySelections(picked);
        throw StateError(
          '当前设备未检测到 FBI CIA Bridge 补丁能力，仅能使用 CIA 安装服务。'
          '请先在 3DS 上安装并打开 FBI CIA Bridge。',
        );
      }
      final archive = archives.single;
      final path = archive.path;
      if (path == null || path.isEmpty) {
        await _deleteTemporarySelections(picked);
        throw const FileSystemException('无法读取所选补丁 ZIP');
      }
      await _preparePatch(
        PatchInput.local(
          path,
          label: archive.name,
          deleteLocalPath: archive.deleteLocalPath,
        ),
      );
      return;
    }
    if (picked.isNotEmpty && preparedPatch != null) {
      final previous = preparedPatch;
      preparedPatch = null;
      patchTitleInfo = null;
      unawaited(previous!.delete());
      targetPort = selectedDevice?.port ?? 5000;
    }
    var ignored = 0;
    final addedCiaIds = <String>[];
    for (final file in picked) {
      if (!file.isSupported) {
        ignored++;
        continue;
      }
      final existing = files.indexWhere((item) => item.id == file.id);
      if (existing < 0) {
        final selected = file.isCia
            ? file.withCiaMetadata(state: CiaMetadataState.loading)
            : file;
        files.add(selected);
        if (file.isCia) addedCiaIds.add(file.id);
      }
    }
    status = files.isEmpty
        ? '没有选择支持的文件'
        : addedCiaIds.isEmpty
        ? _selectionStatus(ignored: ignored)
        : '已选择 ${files.length} 个文件，正在读取 CIA 软件信息…';
    _notify();

    for (final id in addedCiaIds) {
      await _inspectCia(id);
    }
    if (files.isNotEmpty) {
      status = _selectionStatus(ignored: ignored);
      _notify();
    }
  }

  Future<void> _preparePatch(PatchInput? input) async {
    if (input == null) return;

    buildingPatch = true;
    status = '正在刷新 3DS 补丁能力…';
    _notify();
    try {
      await _refreshSelectedPatchCapabilities();
      status = '正在扫描并准备 LayeredFS 快速安装流…';
      _notify();
      final next = await _patchBuilder.buildInput(
        input,
        options: PatchBuildOptions(
          titleRootPaths: selectedDevice?.supportsPatchTitleRoot ?? false,
          zlib: selectedDevice?.supportsPatchZlib ?? false,
        ),
        onProgress: (completed, total, path) {
          if (completed == total || completed % 50 == 0) {
            status = '正在打包补丁 $completed / $total · $path';
            _notify();
          }
        },
      );
      final previous = preparedPatch;
      preparedPatch = next;
      patchTitleInfo = null;
      files.clear();
      if (previous != null) unawaited(previous.delete());
      final device = selectedDevice;
      targetPort = device?.patchPort ?? 5002;
      status = _patchReadyStatus(next);
      unawaited(_resolvePatchTitleInfo(next));
    } catch (_) {
      status = '补丁准备失败，请检查 ZIP 内的 LayeredFS 结构';
      rethrow;
    } finally {
      await input.dispose();
      buildingPatch = false;
      _notify();
    }
  }

  Future<void> _refreshSelectedPatchCapabilities() async {
    final current = selectedDevice;
    final address = selectedAddress;
    if (current == null ||
        address == null ||
        !current.supportsPatch ||
        current.supportsPatchTitleRoot) {
      return;
    }

    try {
      final found = await _scanDevices(address);
      final refreshed = found
          .where(
            (device) =>
                device.ip == current.ip &&
                device.isProtocolDiscovered &&
                device.supportsPatch,
          )
          .firstOrNull;
      if (refreshed == null) return;

      selectedDevice = refreshed;
      targetIp = refreshed.ip;
      targetPort = refreshed.patchPort!;
      devices = [
        for (final device in devices)
          if (device.ip == refreshed.ip) refreshed else device,
      ];
      if (!devices.any((device) => device.ip == refreshed.ip)) {
        devices = [refreshed, ...devices];
      }
    } catch (_) {
      // Keep the previously discovered capabilities. If the selected patch
      // needs a newer feature, bundle validation will stop before transfer and
      // report the exact missing capability instead of omitting a file.
    }
  }

  Future<void> _deleteTemporarySelections(Iterable<ShareFile> selected) async {
    for (final file in selected) {
      final path = file.path;
      if (!file.deleteLocalPath || path == null || path.isEmpty) continue;
      try {
        final local = File(path);
        if (await local.exists()) await local.delete();
      } catch (_) {
        // The platform cache is also pruned by age on the next selection.
      }
    }
  }

  Future<void> _resolvePatchTitleInfo(PreparedPatch patch) async {
    try {
      final dataDirectory = await _bridge.dataDirectory();
      final info = await _patchTitleInfoService.resolve(
        patch.titleId,
        dataDirectory: dataDirectory,
      );
      if (preparedPatch?.bundleId != patch.bundleId) return;
      patchTitleInfo = info;
      if (phase == TransferPhase.idle) status = _patchReadyStatus(patch);
      _notify();
    } catch (_) {
      // Title information is optional; patch transport remains fully offline.
    }
  }

  String _patchReadyStatus(PreparedPatch patch) {
    final name = patchTitleInfo?.name ?? patch.sourceLabel;
    final sizeText = patch.storedBytes < patch.rawBytes
        ? '${formatBytes(patch.rawBytes)} 原始 / '
              '${formatBytes(patch.storedBytes)} 传输'
        : '${formatBytes(patch.rawBytes)} raw 传输';
    return '已准备 $name · Title ID ${patch.titleId} · '
        '${patch.fileCount} 个文件 · '
        '$sizeText · 快速增量安装';
  }

  Future<void> _inspectCia(String id) async {
    final beforeRead = files.indexWhere((item) => item.id == id);
    if (beforeRead < 0) return;
    final file = files[beforeRead];
    try {
      final metadata = await _metadataParser.parse(
        fileSize: file.size,
        readRange: ({required offset, required length}) =>
            _bridge.readFileRange(file, offset: offset, length: length),
      );
      final current = files.indexWhere((item) => item.id == id);
      if (current < 0) return;
      files[current] = files[current].withCiaMetadata(
        state: CiaMetadataState.available,
        metadata: metadata,
      );
    } on Object catch (error) {
      final current = files.indexWhere((item) => item.id == id);
      if (current < 0) return;
      files[current] = files[current].withCiaMetadata(
        state: CiaMetadataState.unavailable,
        error: _cleanMetadataError(error),
      );
    }
    _notify();
  }

  String _selectionStatus({required int ignored}) {
    final recognized = files
        .where((file) => file.metadataState == CiaMetadataState.available)
        .length;
    final unavailable = files
        .where((file) => file.metadataState == CiaMetadataState.unavailable)
        .length;
    final details = <String>[
      if (recognized > 0) '已识别 $recognized 个 CIA',
      if (unavailable > 0) '$unavailable 个 CIA 信息不可用',
      if (ignored > 0) '忽略 $ignored 个不支持的文件',
    ];
    return '已准备 ${files.length} 个文件${details.isEmpty ? '' : '，${details.join('，')}'}';
  }

  String _cleanMetadataError(Object error) => error
      .toString()
      .replaceFirst(
        RegExp(
          r'^(FormatException|FileSystemException|PlatformException|UnsupportedError|StateError):\s*',
        ),
        '',
      )
      .trim();

  void removeFile(ShareFile file) {
    files.removeWhere((item) => item.id == file.id);
    _notify();
  }

  void clearFiles() {
    files.clear();
    final patch = preparedPatch;
    preparedPatch = null;
    patchTitleInfo = null;
    if (patch != null) unawaited(patch.delete());
    targetPort = selectedDevice?.port ?? 5000;
    _notify();
  }

  void setMode(TransferMode value) {
    mode = value;
    _notify();
  }

  void setAddress(String? value) {
    _deviceScanGeneration++;
    selectedAddress = value;
    devices = [];
    selectedDevice = null;
    _notify();
    unawaited(refreshDevices());
  }

  Future<void> refreshDevices() async {
    final address = selectedAddress;
    if (address == null || scanningDevices || serverRunning) return;
    final generation = _deviceScanGeneration;
    scanningDevices = true;
    discoveryStatus = '正在扫描 $address 所在的局域网…';
    _notify();
    try {
      final selectedBeforeScan = selectedDevice;
      final found = await _scanDevices(address);
      if (generation != _deviceScanGeneration || selectedAddress != address) {
        return;
      }
      devices = found;
      if (selectedBeforeScan != null) {
        selectedDevice =
            found
                .where((item) => item.ip == selectedBeforeScan.ip)
                .firstOrNull ??
            selectedBeforeScan;
      }
      if (selectedDevice != null) {
        targetIp = selectedDevice!.ip;
        targetPort = isPatchMode
            ? selectedDevice!.patchPort ?? 5002
            : selectedDevice!.port;
      }
      discoveryStatus = found.isEmpty
          ? '暂未发现 Nintendo 设备；请唤醒 3DS 后重试'
          : found.every((device) => device.isProtocolDiscovered)
          ? '发现 ${found.length} 台正在等待接收的 3DS'
          : found.every((device) => device.isCandidate)
          ? '发现 ${found.length} 个在线候选；请对照 3DS 屏幕上的 IP 选择'
          : '发现 ${found.length} 台 Nintendo 设备';
    } catch (error) {
      if (generation != _deviceScanGeneration || selectedAddress != address) {
        return;
      }
      discoveryStatus = '自动发现不可用，可手动添加 3DS';
    } finally {
      final shouldRescan =
          (generation != _deviceScanGeneration || selectedAddress != address) &&
          selectedAddress != null &&
          !serverRunning;
      scanningDevices = false;
      _notify();
      if (shouldRescan) unawaited(refreshDevices());
    }
  }

  void selectDevice(NearbyDevice device) {
    final discardedPatch = isPatchMode && !device.supportsPatch;
    if (discardedPatch) {
      final previous = preparedPatch;
      preparedPatch = null;
      patchTitleInfo = null;
      if (previous != null) unawaited(previous.delete());
    }
    selectedDevice = device;
    targetIp = device.ip;
    targetPort = isPatchMode ? device.patchPort! : device.port;
    mode = TransferMode.push;
    status = device.supportsPatch
        ? '已连接 FBI CIA Bridge · 支持 CIA 安装和 LayeredFS 补丁'
        : discardedPatch
        ? '当前 FBI 仅支持 CIA 安装，已移除不可发送的 LayeredFS 补丁'
        : '未检测到 FBI CIA Bridge 补丁能力 · 当前仅支持 CIA 安装';
    _notify();
  }

  void addManualDevice(String ip, {int port = 5000, int? patchPort}) {
    final trimmed = ip.trim();
    final octets = trimmed.split('.');
    if (octets.length != 4 ||
        octets.any((part) {
          final value = int.tryParse(part);
          return value == null || value < 0 || value > 255;
        })) {
      throw StateError('请输入有效的 3DS IPv4 地址');
    }
    if (port < 1 || port > 65535) throw StateError('接收端口必须在 1–65535 之间');
    if (patchPort != null && (patchPort < 1 || patchPort > 65535)) {
      throw StateError('补丁端口必须在 1–65535 之间');
    }
    final manual = NearbyDevice(
      ip: trimmed,
      mac: '',
      port: port,
      patchPort: patchPort,
      supportsPatchTitleRoot: patchPort != null,
      supportsPatchZlib: patchPort != null,
      isManual: true,
    );
    devices = [manual, ...devices.where((device) => device.ip != trimmed)];
    selectedDevice = manual;
    targetIp = trimmed;
    targetPort = isPatchMode && patchPort != null ? patchPort : port;
    mode = TransferMode.push;
    status = patchPort == null
        ? '已添加 3DS · $trimmed · 支持安装文件'
        : '已添加 3DS · $trimmed · 支持安装文件和 LayeredFS 补丁';
    _notify();
  }

  Future<void> startQr() async {
    if (isPatchMode) {
      throw StateError(
        'LayeredFS 补丁仅支持推送，请在 3DS 的 FBI 中打开 '
        '“Remote Install / Receive URLs over the network”',
      );
    }
    _validateCommon();
    await _startHosting();
    phase = TransferPhase.hosting;
    status = session!.usedFallbackPort
        ? '首选端口被占用，已自动改用 ${session!.port}；等待 3DS 扫码'
        : '二维码已就绪，等待 3DS 扫码下载';
    _notify();
  }

  Future<void> startPush() async {
    _validateCommon();
    if (targetIp.trim().isEmpty) {
      throw StateError('请填写 3DS 接收端屏幕上显示的 IP');
    }
    if (targetPort < 1 || targetPort > 65535) {
      throw StateError('接收端口必须在 1–65535 之间');
    }
    await _startHosting();
    phase = TransferPhase.connecting;
    status = '正在连接 $targetIp:$targetPort…';
    _notify();

    unawaited(
      _fbi
          .send(
            host: targetIp,
            port: targetPort,
            urls: session!.urls,
            onStage: _handleFbiStage,
          )
          .catchError((_) {}),
    );
  }

  Future<void> _startHosting() async {
    _fbi.cancel();
    phase = TransferPhase.preparing;
    status = '正在启动局域网文件服务…';
    bytesServed = 0;
    totalBytes = selectedBytes;
    _resetTransferMetrics();
    _notify();
    session = await _bridge.start(
      files: selectedFiles,
      advertisedAddress: selectedAddress!,
      preferredPort: httpPort,
    );
    serverRunning = true;
    totalBytes = session!.totalBytes;
  }

  void _validateCommon() {
    if (selectedFiles.isEmpty) {
      throw StateError('请先选择安装文件或 LayeredFS 补丁目录');
    }
    if (selectedAddress == null || selectedAddress!.isEmpty) {
      throw StateError('没有可用的局域网 IPv4 地址');
    }
    if (isPatchMode && selectedDevice?.supportsPatch != true) {
      throw StateError(
        '当前设备的 FBI 仅支持 CIA 安装，不支持 LayeredFS 补丁。'
        '请安装 FBI CIA Bridge 后重试。',
      );
    }
    if (httpPort < 0 || httpPort > 65535) {
      throw StateError('HTTP 端口必须在 0–65535 之间');
    }
  }

  void _handleFbiStage(FbiClientStage stage, Object? error) {
    switch (stage) {
      case FbiClientStage.connecting:
        phase = TransferPhase.connecting;
        status = '正在连接 3DS 接收端…';
      case FbiClientStage.urlsSent:
        phase = TransferPhase.waitingForFbi;
        status = isPatchMode
            ? '补丁链接已发送，请在 3DS 上确认直接覆盖；如中断请重新发送同一补丁'
            : '链接已发送，请在 3DS 上确认安装';
      case FbiClientStage.acknowledged:
        phase = TransferPhase.complete;
        status = '3DS 接收端已完成本次请求，局域网服务已停止';
        serverRunning = false;
        transferActive = false;
        estimatedCompletionAt = null;
        unawaited(_bridge.stop());
      case FbiClientStage.cancelled:
        return;
      case FbiClientStage.failed:
        phase = TransferPhase.error;
        transferActive = false;
        estimatedCompletionAt = null;
        status = isPatchMode
            ? '连接 3DS 接收端失败：${_cleanError(error)}。请确认接收页面仍保持打开。'
            : '连接 3DS 接收端失败：${_cleanError(error)}。文件服务仍在运行，可切换扫码。';
    }
    _notify();
  }

  void _handleHostEvent(HostEvent event) {
    switch (event.type) {
      case HostEventType.downloadStarted:
        phase = TransferPhase.transferring;
        _beginTransferMeasurement();
        status = isPatchMode
            ? '3DS 正在流式接收并写入 ${event.fileName}'
            : '3DS 正在接收 ${event.fileName}';
      case HostEventType.progress:
        phase = TransferPhase.transferring;
        bytesServed = event.sessionBytes;
        totalBytes = event.sessionTotal;
        _updateTransferMeasurement();
        status = '正在传输 ${event.fileName}';
      case HostEventType.downloadFinished:
        bytesServed = event.sessionBytes;
        totalBytes = event.sessionTotal;
        transferActive = false;
        estimatedCompletionAt = null;
        status = '已传完 ${event.fileName}，等待 3DS 安装/确认…';
      case HostEventType.error:
        transferActive = false;
        estimatedCompletionAt = null;
        status = '传输提示：${event.message}';
      case HostEventType.stopped:
        serverRunning = false;
        transferActive = false;
        estimatedCompletionAt = null;
        if (phase != TransferPhase.complete) {
          phase = TransferPhase.idle;
          status = '局域网服务已停止';
        }
    }
    _notify();
  }

  void _beginTransferMeasurement() {
    if (transferActive) return;
    transferActive = true;
    _lastProgressAt = _now();
    _lastProgressBytes = bytesServed;
    estimatedCompletionAt = null;
  }

  void _updateTransferMeasurement() {
    if (!transferActive) _beginTransferMeasurement();
    final now = _now();
    final previousAt = _lastProgressAt;
    final elapsed = previousAt == null
        ? Duration.zero
        : now.difference(previousAt);
    final byteDelta = bytesServed - _lastProgressBytes;

    if (byteDelta > 0 && elapsed.inMilliseconds >= 120) {
      final sample = byteDelta / (elapsed.inMicroseconds / 1000000);
      transferBytesPerSecond = _speedSampleCount == 0
          ? sample
          : (transferBytesPerSecond * 0.72) + (sample * 0.28);
      _speedSampleCount++;
      _lastProgressAt = now;
      _lastProgressBytes = bytesServed;
    }

    final remainingBytes = totalBytes - bytesServed;
    if (remainingBytes > 0 && transferBytesPerSecond > 0) {
      final remainingMilliseconds =
          (remainingBytes / transferBytesPerSecond * 1000).ceil();
      estimatedCompletionAt = now.add(
        Duration(milliseconds: remainingMilliseconds),
      );
    } else {
      estimatedCompletionAt = null;
    }
  }

  void _resetTransferMetrics() {
    transferActive = false;
    transferBytesPerSecond = 0;
    estimatedCompletionAt = null;
    _lastProgressAt = null;
    _lastProgressBytes = 0;
    _speedSampleCount = 0;
  }

  Future<void> stop() async {
    _fbi.cancel();
    await _bridge.stop();
    serverRunning = false;
    session = null;
    bytesServed = 0;
    totalBytes = 0;
    _resetTransferMetrics();
    phase = TransferPhase.idle;
    status = '局域网服务已停止';
    _notify();
  }

  void finishResult({bool clearSelection = false}) {
    if (clearSelection) clearFiles();
    session = null;
    bytesServed = 0;
    totalBytes = 0;
    _resetTransferMetrics();
    phase = TransferPhase.idle;
    status = clearSelection ? '选择文件后即可发送到 3DS' : '可以继续发送当前文件';
    _notify();
  }

  void useQrFallback() {
    if (isPatchMode) return;
    if (!serverRunning || session == null) return;
    mode = TransferMode.qr;
    phase = TransferPhase.hosting;
    status = '二维码已就绪，请在 3DS 接收端选择 Scan QR Code';
    _notify();
  }

  String _cleanError(Object? error) {
    final text = error?.toString() ?? '未知错误';
    return text.replaceFirst(RegExp(r'^(SocketException|StateError):\s*'), '');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _fbi.cancel();
    unawaited(_bridge.stop());
    final patch = preparedPatch;
    if (patch != null) unawaited(patch.delete());
    super.dispose();
  }
}
