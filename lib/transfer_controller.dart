import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/fbi_protocol_client.dart';
import 'core/device_discovery.dart';
import 'core/lan_addresses.dart';
import 'core/models.dart';
import 'platform/file_host_bridge.dart';

class TransferController extends ChangeNotifier {
  TransferController({
    FileHostBridge? bridge,
    Future<List<String>> Function()? addressFinder,
    Future<List<NearbyDevice>> Function(String address)? deviceScanner,
  }) : _bridge = bridge ?? FileHostBridge(),
       _addressFinder = addressFinder ?? findLanIpv4Addresses {
    _bridge.onEvent = _handleHostEvent;
    _scanDevices = deviceScanner ?? DeviceDiscovery(_bridge.listNeighbors).scan;
  }

  final FileHostBridge _bridge;
  final Future<List<String>> Function() _addressFinder;
  late final Future<List<NearbyDevice>> Function(String address) _scanDevices;
  final FbiProtocolClient _fbi = FbiProtocolClient();

  final List<ShareFile> files = [];
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
  String status = '选择 CIA 后即可通过局域网交给 FBI';
  int bytesServed = 0;
  int totalBytes = 0;
  bool serverRunning = false;
  int _deviceScanGeneration = 0;
  bool _disposed = false;

  bool get isBusy =>
      phase == TransferPhase.preparing || phase == TransferPhase.connecting;

  double? get progress {
    if (totalBytes <= 0) return null;
    return (bytesServed / totalBytes).clamp(0, 1);
  }

  int get selectedBytes => files.fold(0, (total, file) => total + file.size);

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
    var ignored = 0;
    for (final file in picked) {
      if (!file.isSupported) {
        ignored++;
        continue;
      }
      final existing = files.indexWhere((item) => item.id == file.id);
      if (existing < 0) files.add(file);
    }
    status = files.isEmpty
        ? '没有选择支持的文件'
        : '已准备 ${files.length} 个文件${ignored > 0 ? '，忽略 $ignored 个不支持的文件' : ''}';
    _notify();
  }

  void removeFile(ShareFile file) {
    files.removeWhere((item) => item.id == file.id);
    _notify();
  }

  void clearFiles() {
    files.clear();
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
      if (selectedDevice != null) targetIp = selectedDevice!.ip;
      discoveryStatus = found.isEmpty
          ? '暂未发现 Nintendo 设备；请唤醒 3DS 后重试'
          : found.every((device) => device.isCandidate)
          ? '发现 ${found.length} 个在线候选；请对照 FBI 屏幕上的 IP 选择'
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
    selectedDevice = device;
    targetIp = device.ip;
    mode = TransferMode.push;
    status = '已选择 ${device.name} · ${device.ip}';
    _notify();
  }

  void addManualDevice(String ip, {int port = 5000}) {
    final trimmed = ip.trim();
    final octets = trimmed.split('.');
    if (octets.length != 4 ||
        octets.any((part) {
          final value = int.tryParse(part);
          return value == null || value < 0 || value > 255;
        })) {
      throw StateError('请输入有效的 3DS IPv4 地址');
    }
    if (port < 1 || port > 65535) throw StateError('FBI 端口必须在 1–65535 之间');
    final manual = NearbyDevice(ip: trimmed, mac: '', isManual: true);
    devices = [manual, ...devices.where((device) => device.ip != trimmed)];
    selectedDevice = manual;
    targetIp = trimmed;
    targetPort = port;
    mode = TransferMode.push;
    status = '已添加 3DS · $trimmed';
    _notify();
  }

  Future<void> startQr() async {
    _validateCommon();
    await _startHosting();
    phase = TransferPhase.hosting;
    status = session!.usedFallbackPort
        ? '首选端口被占用，已自动改用 ${session!.port}；等待 FBI 扫码'
        : '二维码已就绪，等待 FBI 扫码下载';
    _notify();
  }

  Future<void> startPush() async {
    _validateCommon();
    if (targetIp.trim().isEmpty) {
      throw StateError('请填写 FBI 屏幕上显示的 3DS IP');
    }
    if (targetPort < 1 || targetPort > 65535) {
      throw StateError('FBI 端口必须在 1–65535 之间');
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
    _notify();
    session = await _bridge.start(
      files: List.unmodifiable(files),
      advertisedAddress: selectedAddress!,
      preferredPort: httpPort,
    );
    serverRunning = true;
    totalBytes = session!.totalBytes;
  }

  void _validateCommon() {
    if (files.isEmpty) throw StateError('请先选择至少一个 CIA 文件');
    if (selectedAddress == null || selectedAddress!.isEmpty) {
      throw StateError('没有可用的局域网 IPv4 地址');
    }
    if (httpPort < 0 || httpPort > 65535) {
      throw StateError('HTTP 端口必须在 0–65535 之间');
    }
  }

  void _handleFbiStage(FbiClientStage stage, Object? error) {
    switch (stage) {
      case FbiClientStage.connecting:
        phase = TransferPhase.connecting;
        status = '正在连接 3DS 的 FBI…';
      case FbiClientStage.urlsSent:
        phase = TransferPhase.waitingForFbi;
        status = '链接已发送，请在 3DS 上确认安装';
      case FbiClientStage.acknowledged:
        phase = TransferPhase.complete;
        status = 'FBI 已完成本次请求，局域网服务已停止';
        serverRunning = false;
        unawaited(_bridge.stop());
      case FbiClientStage.cancelled:
        return;
      case FbiClientStage.failed:
        phase = TransferPhase.error;
        status = '连接 FBI 失败：${_cleanError(error)}。文件服务仍在运行，可切换扫码。';
    }
    _notify();
  }

  void _handleHostEvent(HostEvent event) {
    switch (event.type) {
      case HostEventType.downloadStarted:
        phase = TransferPhase.transferring;
        status = 'FBI 正在下载 ${event.fileName}';
      case HostEventType.progress:
        phase = TransferPhase.transferring;
        bytesServed = event.sessionBytes;
        totalBytes = event.sessionTotal;
        status =
            '正在传输 ${event.fileName} · ${formatBytes(bytesServed)} / ${formatBytes(totalBytes)}';
      case HostEventType.downloadFinished:
        status = '已传完 ${event.fileName}，等待 FBI 安装/确认…';
      case HostEventType.error:
        status = '传输提示：${event.message}';
      case HostEventType.stopped:
        serverRunning = false;
        if (phase != TransferPhase.complete) {
          phase = TransferPhase.idle;
          status = '局域网服务已停止';
        }
    }
    _notify();
  }

  Future<void> stop() async {
    _fbi.cancel();
    await _bridge.stop();
    serverRunning = false;
    session = null;
    bytesServed = 0;
    totalBytes = 0;
    phase = TransferPhase.idle;
    status = '局域网服务已停止';
    _notify();
  }

  void finishResult({bool clearSelection = false}) {
    if (clearSelection) files.clear();
    session = null;
    bytesServed = 0;
    totalBytes = 0;
    phase = TransferPhase.idle;
    status = clearSelection ? '选择文件后即可发送到 3DS' : '可以继续发送当前文件';
    _notify();
  }

  void useQrFallback() {
    if (!serverRunning || session == null) return;
    mode = TransferMode.qr;
    phase = TransferPhase.hosting;
    status = '二维码已就绪，请在 FBI 中选择 Scan QR Code';
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
    super.dispose();
  }
}
