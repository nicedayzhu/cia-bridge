import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../core/models.dart';
import '../transfer_controller.dart';
import 'game_icons.dart';
import 'transfer_panel.dart';

enum _FlowStage { device, files }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    this.initializeController = true,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  });

  final TransferController controller;
  final bool initializeController;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const _autoRefreshInterval = Duration(seconds: 15);

  Timer? _autoRefreshTimer;
  bool _isForeground = true;
  late _FlowStage _stage;

  TransferController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _stage =
        controller.session != null ||
            (controller.selectedDevice != null && controller.files.isNotEmpty)
        ? _FlowStage.files
        : _FlowStage.device;
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_refresh);
    if (widget.initializeController) {
      controller.initialize().catchError(_showError);
    }
    _autoRefreshTimer = Timer.periodic(
      _autoRefreshInterval,
      (_) => _refreshDevicesAutomatically(),
    );
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_refresh);
    controller.addListener(_refresh);
    _stage =
        controller.session != null ||
            (controller.selectedDevice != null && controller.files.isNotEmpty)
        ? _FlowStage.files
        : _FlowStage.device;
    if (widget.initializeController) {
      controller.initialize().catchError(_showError);
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_refresh);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    if (_isForeground) unawaited(_refreshDevicesAutomatically());
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      if (_stage == _FlowStage.files &&
          controller.selectedDevice == null &&
          controller.session == null) {
        _stage = _FlowStage.device;
      }
    });
  }

  Future<void> _refreshDevicesAutomatically() async {
    if (!mounted ||
        !_isForeground ||
        _stage != _FlowStage.device ||
        controller.serverRunning ||
        controller.scanningDevices ||
        controller.scanningAddresses) {
      return;
    }
    if (controller.selectedAddress == null) {
      await controller.refreshAddresses();
    }
    if (!mounted ||
        _stage != _FlowStage.device ||
        controller.selectedAddress == null) {
      return;
    }
    await controller.refreshDevices();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            themeMode: widget.themeMode,
            onThemeModeChanged: widget.onThemeModeChanged,
            onNetworkSettings: _showNetworkSettings,
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final slide = Tween<Offset>(
                  begin: const Offset(0.025, 0),
                  end: Offset.zero,
                ).animate(animation);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(position: slide, child: child),
                );
              },
              child: _stage == _FlowStage.device
                  ? _DeviceStage(
                      key: const ValueKey('device-stage'),
                      controller: controller,
                      onSelectDevice: _selectDevice,
                      onManualDevice: _showManualDevice,
                    )
                  : _FilesStage(
                      key: const ValueKey('files-stage'),
                      controller: controller,
                      onChangeDevice: _changeDevice,
                      onPickFiles: _pickFiles,
                      onSend: _sendSelectedDevice,
                      onQr: _startQr,
                      onStop: _stop,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _selectDevice(NearbyDevice device) {
    controller.selectDevice(device);
    setState(() => _stage = _FlowStage.files);
  }

  void _changeDevice() {
    if (controller.serverRunning) return;
    setState(() => _stage = _FlowStage.device);
    _refreshDevicesAutomatically();
  }

  Future<void> _pickFiles() async {
    try {
      await controller.pickFiles();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _sendSelectedDevice() async {
    try {
      if (controller.files.isEmpty) throw StateError('请先选择要发送的 CIA 文件');
      final device = controller.selectedDevice;
      if (device == null) throw StateError('请先选择一台附近的 3DS');
      controller.selectDevice(device);
      await controller.startPush();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _startQr() async {
    try {
      controller.setMode(TransferMode.qr);
      await controller.startQr();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _stop() async {
    try {
      await controller.stop();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _showManualDevice() async {
    final ip = TextEditingController(text: controller.targetIp);
    final port = TextEditingController(text: '${controller.targetPort}');
    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('手动添加 3DS'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '在 FBI 中打开 “Receive URLs over the network”，然后输入屏幕显示的 IP。',
                style: TextStyle(color: context.mutedColor, height: 1.45),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: ip,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '3DS IP',
                  hintText: '192.168.1.35',
                  prefixIcon: Icon(Icons.videogame_asset_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'FBI 端口',
                  helperText: '默认 5000',
                  prefixIcon: Icon(Icons.lan_outlined),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.arrow_forward_rounded, size: 18),
            label: const Text('继续'),
          ),
        ],
      ),
    );
    if (added == true) {
      try {
        controller.addManualDevice(
          ip.text,
          port: int.tryParse(port.text) ?? 5000,
        );
        if (mounted && controller.selectedDevice != null) {
          setState(() => _stage = _FlowStage.files);
        }
      } catch (error) {
        _showError(error);
      }
    }
    ip.dispose();
    port.dispose();
  }

  Future<void> _showNetworkSettings() async {
    final port = TextEditingController(text: '${controller.httpPort}');
    unawaited(controller.refreshAddresses());
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final selected =
                controller.addresses.contains(controller.selectedAddress)
                ? controller.selectedAddress
                : null;
            return AlertDialog(
              title: const Text('网络设置'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        '${controller.addresses.join('|')}|$selected',
                      ),
                      initialValue: selected,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '本机局域网地址',
                        prefixIcon: Icon(Icons.wifi_tethering_rounded),
                      ),
                      hint: const Text('尚未检测到可用地址'),
                      items: controller.addresses
                          .map(
                            (address) => DropdownMenuItem(
                              value: address,
                              child: Text(address),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: controller.addresses.isEmpty
                          ? null
                          : controller.setAddress,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            controller.addressStatus,
                            style: TextStyle(
                              color: context.mutedColor,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('refresh-addresses-button'),
                          onPressed: controller.scanningAddresses
                              ? null
                              : () => controller.refreshAddresses(),
                          icon: controller.scanningAddresses
                              ? const SizedBox.square(
                                  dimension: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('重新检测'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: port,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'HTTP 端口',
                        helperText: '默认 8080；冲突时自动回退',
                        prefixIcon: Icon(Icons.http_rounded),
                      ),
                      onChanged: (value) =>
                          controller.httpPort = int.tryParse(value) ?? 8080,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('完成'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      port.dispose();
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    final message = error.toString().replaceFirst(
      RegExp(r'^(StateError|ArgumentError|PlatformException)[:(]\s*'),
      '',
    );
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.onNetworkSettings,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final VoidCallback onNetworkSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 70,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outline),
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    const GameBridgeLogo(size: 40),
                    const SizedBox(width: 11),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'CIA Bridge',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.25,
                                ),
                              ),
                              if (constraints.maxWidth > 220)
                                Text(
                                  '把 CIA 送到你的 Nintendo 3DS',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.mutedColor,
                                    fontSize: 10.5,
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    _ThemeMenu(
                      themeMode: themeMode,
                      onChanged: onThemeModeChanged,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '网络设置',
                      onPressed: onNetworkSettings,
                      icon: const Icon(Icons.tune_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeMenu extends StatelessWidget {
  const _ThemeMenu({required this.themeMode, required this.onChanged});

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final icon = switch (themeMode) {
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };
    return PopupMenuButton<ThemeMode>(
      key: const Key('theme-menu-button'),
      tooltip: '切换主题',
      initialValue: themeMode,
      onSelected: onChanged,
      icon: Icon(icon),
      itemBuilder: (context) => [
        _themeItem(
          mode: ThemeMode.system,
          current: themeMode,
          icon: Icons.brightness_auto_rounded,
          label: '跟随系统',
        ),
        _themeItem(
          mode: ThemeMode.light,
          current: themeMode,
          icon: Icons.light_mode_rounded,
          label: '浅色',
        ),
        _themeItem(
          mode: ThemeMode.dark,
          current: themeMode,
          icon: Icons.dark_mode_rounded,
          label: '深色',
        ),
      ],
    );
  }

  static PopupMenuItem<ThemeMode> _themeItem({
    required ThemeMode mode,
    required ThemeMode current,
    required IconData icon,
    required String label,
  }) {
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 11),
          Expanded(child: Text(label)),
          if (mode == current) const Icon(Icons.check_rounded, size: 18),
        ],
      ),
    );
  }
}

class _DeviceStage extends StatelessWidget {
  const _DeviceStage({
    super.key,
    required this.controller,
    required this.onSelectDevice,
    required this.onManualDevice,
  });

  final TransferController controller;
  final ValueChanged<NearbyDevice> onSelectDevice;
  final VoidCallback onManualDevice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 42),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _FlowProgress(stage: _FlowStage.device),
                const SizedBox(height: 34),
                Center(
                  child: Container(
                    width: 94,
                    height: 94,
                    padding: const EdgeInsets.all(17),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.secondary.withValues(alpha: 0.18),
                          theme.colorScheme.primary.withValues(alpha: 0.18),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.25,
                        ),
                      ),
                    ),
                    child: Nintendo3dsGlyph(
                      size: 60,
                      bodyColor: theme.colorScheme.onSurface,
                      screenColor: AppColors.cyan,
                      detailColor: theme.colorScheme.secondary,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  '选择你的 Nintendo 3DS',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '在 FBI → Remote Install 中打开 “Receive URLs over the network”',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: context.mutedColor,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 24),
                _DiscoveryBar(
                  controller: controller,
                  onManualDevice: onManualDevice,
                ),
                const SizedBox(height: 18),
                if (controller.devices.isEmpty)
                  _DeviceEmptyState(scanning: controller.scanningDevices)
                else
                  for (final device in controller.devices)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _DeviceChoiceCard(
                        device: device,
                        onTap: () => onSelectDevice(device),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DiscoveryBar extends StatelessWidget {
  const _DiscoveryBar({required this.controller, required this.onManualDevice});

  final TransferController controller;
  final VoidCallback onManualDevice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 11, 11),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 570;
          final status = Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: controller.scanningDevices
                      ? theme.colorScheme.primary
                      : AppColors.success,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  controller.discoveryStatus,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.mutedColor, fontSize: 12.5),
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              OutlinedButton.icon(
                key: const Key('refresh-devices-button'),
                onPressed: controller.scanningDevices
                    ? null
                    : () => controller.refreshDevices(),
                icon: controller.scanningDevices
                    ? const SizedBox.square(
                        dimension: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar_rounded, size: 18),
                label: Text(controller.scanningDevices ? '扫描中' : '重新扫描'),
              ),
              TextButton.icon(
                onPressed: onManualDevice,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('手动添加'),
              ),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                status,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: status),
              const SizedBox(width: 14),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _DeviceChoiceCard extends StatelessWidget {
  const _DeviceChoiceCard({required this.device, required this.onTap});

  final NearbyDevice device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(19),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Nintendo3dsGlyph(
                  size: 38,
                  bodyColor: theme.colorScheme.onSurface,
                  screenColor: AppColors.cyan,
                  detailColor: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            device.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (device.isManual) ...[
                          const SizedBox(width: 8),
                          _MiniBadge(label: '手动'),
                        ] else if (device.isProtocolDiscovered) ...[
                          const SizedBox(width: 8),
                          _MiniBadge(label: 'FBI 就绪'),
                        ] else if (device.isCandidate) ...[
                          const SizedBox(width: 8),
                          _MiniBadge(label: '候选'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      device.isProtocolDiscovered
                          ? '${device.ip}:${device.port} · 已开启网络接收'
                          : device.isCandidate
                          ? '${device.ip} · 请与 FBI 屏幕 IP 核对'
                          : device.ip,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: context.mutedColor, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '选择',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 15,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceEmptyState extends StatelessWidget {
  const _DeviceEmptyState({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: context.softSurface,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Nintendo3dsGlyph(
              size: 32,
              bodyColor: context.mutedColor,
              screenColor: context.mutedColor.withValues(alpha: 0.3),
              detailColor: context.mutedColor,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  scanning ? '正在寻找附近的 3DS…' : '还没有发现 3DS',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  scanning ? '扫描完成后会自动显示在这里' : '唤醒主机后重新扫描，或手动添加 IP',
                  style: TextStyle(color: context.mutedColor, fontSize: 12),
                ),
              ],
            ),
          ),
          if (scanning)
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

class _FilesStage extends StatelessWidget {
  const _FilesStage({
    super.key,
    required this.controller,
    required this.onChangeDevice,
    required this.onPickFiles,
    required this.onSend,
    required this.onQr,
    required this.onStop,
  });

  final TransferController controller;
  final VoidCallback onChangeDevice;
  final Future<void> Function() onPickFiles;
  final Future<void> Function() onSend;
  final Future<void> Function() onQr;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final hasSession = controller.serverRunning || controller.session != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 28, 18, 44),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _FlowProgress(stage: _FlowStage.files),
                const SizedBox(height: 28),
                _SelectedDeviceSummary(
                  device: controller.selectedDevice,
                  enabled: !controller.serverRunning,
                  onChangeDevice: onChangeDevice,
                ),
                const SizedBox(height: 28),
                if (hasSession)
                  TransferPanel(
                    controller: controller,
                    onStop: onStop,
                    onContinue: () => controller.finishResult(),
                    onClear: () =>
                        controller.finishResult(clearSelection: true),
                    onQrFallback: controller.useQrFallback,
                  )
                else ...[
                  _FileSelectionArea(
                    controller: controller,
                    onPickFiles: onPickFiles,
                  ),
                  if (controller.files.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SendConfirmation(
                      controller: controller,
                      onSend: onSend,
                      onQr: onQr,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SelectedDeviceSummary extends StatelessWidget {
  const _SelectedDeviceSummary({
    required this.device,
    required this.enabled,
    required this.onChangeDevice,
  });

  final NearbyDevice? device;
  final bool enabled;
  final VoidCallback onChangeDevice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Nintendo3dsGlyph(
              size: 32,
              bodyColor: theme.colorScheme.onSurface,
              screenColor: AppColors.cyan,
              detailColor: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device?.name ?? 'Nintendo 3DS',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 3),
                Text(
                  device?.ip ?? '未选择设备',
                  style: TextStyle(color: context.mutedColor, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: enabled ? onChangeDevice : null,
            icon: const Icon(Icons.swap_horiz_rounded, size: 18),
            label: const Text('更换设备'),
          ),
        ],
      ),
    );
  }
}

class _FileSelectionArea extends StatelessWidget {
  const _FileSelectionArea({
    required this.controller,
    required this.onPickFiles,
  });

  final TransferController controller;
  final Future<void> Function() onPickFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '选择要安装的文件',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w900,
            letterSpacing: -0.35,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '支持 CIA、TIK、CETK 和 3DSX',
          style: TextStyle(color: context.mutedColor, fontSize: 12.5),
        ),
        const SizedBox(height: 14),
        Card(
          child: controller.files.isEmpty
              ? _EmptyFilePicker(onPickFiles: onPickFiles)
              : _SelectedFiles(
                  controller: controller,
                  onPickFiles: onPickFiles,
                ),
        ),
      ],
    );
  }
}

class _EmptyFilePicker extends StatelessWidget {
  const _EmptyFilePicker({required this.onPickFiles});

  final Future<void> Function() onPickFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 520;
          final icon = Container(
            width: 72,
            height: 72,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const CiaCartridgeGlyph(size: 44),
          );
          final copy = Column(
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Text(
                '从这台设备选择 CIA',
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '文件只会在局域网内临时共享，不会上传到公网。',
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.mutedColor,
                  height: 1.35,
                ),
              ),
            ],
          );
          final button = FilledButton.icon(
            onPressed: () => onPickFiles(),
            icon: const Icon(Icons.add_rounded, size: 19),
            label: const Text('选择 CIA 文件'),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: icon),
                const SizedBox(height: 16),
                copy,
                const SizedBox(height: 20),
                button,
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: 18),
              Expanded(child: copy),
              const SizedBox(width: 18),
              button,
            ],
          );
        },
      ),
    );
  }
}

class _SelectedFiles extends StatelessWidget {
  const _SelectedFiles({required this.controller, required this.onPickFiles});

  final TransferController controller;
  final Future<void> Function() onPickFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${controller.files.length} 个文件',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatBytes(controller.selectedBytes),
                      style: TextStyle(color: context.mutedColor, fontSize: 12),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => onPickFiles(),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('继续添加'),
              ),
              IconButton(
                onPressed: controller.clearFiles,
                tooltip: '清空选择',
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: controller.files.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final file = controller.files[index];
                return _FileChip(
                  file: file,
                  onRemove: () => controller.removeFile(file),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.file, required this.onRemove});

  final ShareFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadata = file.ciaMetadata;
    final metadataLine = switch (file.metadataState) {
      CiaMetadataState.loading => '正在读取 CIA 软件信息…',
      CiaMetadataState.available =>
        '${metadata!.kind.label} · ${metadata.versionLabel} · ${metadata.regionLabel}',
      CiaMetadataState.unavailable => 'CIA 软件信息不可用',
      CiaMetadataState.notApplicable => _selectedFileTypeLabel(file),
    };
    final originalName =
        metadata?.displayTitle != null && metadata!.displayTitle != file.name
        ? '${file.name} · ${formatBytes(file.size)}'
        : formatBytes(file.size);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showFileDetails(context, file),
        borderRadius: BorderRadius.circular(15),
        child: Ink(
          width: 310,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: context.softSurface,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: theme.colorScheme.outline),
          ),
          child: Row(
            children: [
              _FileArtwork(file: file, size: 58),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      metadataLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            file.metadataState == CiaMetadataState.unavailable
                            ? theme.colorScheme.error
                            : context.mutedColor,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      originalName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: context.mutedColor, fontSize: 10),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onRemove,
                tooltip: '移除',
                icon: const Icon(Icons.close_rounded, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _selectedFileTypeLabel(ShareFile file) {
  final lower = file.name.toLowerCase();
  if (lower.endsWith('.cia')) return 'CIA 安装包';
  if (lower.endsWith('.tik')) return 'Ticket 文件';
  if (lower.endsWith('.cetk')) return 'CETK 文件';
  if (lower.endsWith('.3dsx')) return '3DSX 应用';
  return '安装文件';
}

class _FileArtwork extends StatelessWidget {
  const _FileArtwork({required this.file, required this.size});

  final ShareFile file;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bytes = file.ciaMetadata?.iconPng;
    final fallback = Center(child: CiaCartridgeGlyph(size: size * 0.58));
    return Container(
      width: size,
      height: size,
      padding: bytes == null ? EdgeInsets.all(size * 0.16) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null
          ? fallback
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.none,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}

Future<void> _showFileDetails(BuildContext context, ShareFile file) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _FileDetailsSheet(file: file),
    );

class _FileDetailsSheet extends StatelessWidget {
  const _FileDetailsSheet({required this.file});

  final ShareFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadata = file.ciaMetadata;
    final unavailable = file.metadataState == CiaMetadataState.unavailable;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 2, 22, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FileArtwork(file: file, size: 68),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.displayName,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        metadata?.kind.label ?? _selectedFileTypeLabel(file),
                        style: TextStyle(color: context.mutedColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _FileDetailRow(label: '文件名', value: file.name),
            _FileDetailRow(label: '文件大小', value: formatBytes(file.size)),
            if (file.metadataState == CiaMetadataState.loading)
              const _FileDetailNotice(text: '正在读取 CIA 内置的软件信息…')
            else if (unavailable)
              _FileDetailNotice(
                text: file.metadataError?.isNotEmpty == true
                    ? '无法读取 CIA 内置信息：${file.metadataError}'
                    : '无法读取 CIA 内置的软件信息。文件仍可正常发送。',
                isError: true,
              )
            else if (metadata != null) ...[
              _FileDetailRow(label: 'Title ID', value: metadata.titleId),
              _FileDetailRow(label: '版本', value: metadata.versionLabel),
              _FileDetailRow(label: '地区', value: metadata.regionLabel),
              if (metadata.publisher?.isNotEmpty == true)
                _FileDetailRow(label: '发行者', value: metadata.publisher!),
              if (metadata.longTitle?.isNotEmpty == true &&
                  metadata.longTitle != metadata.shortTitle)
                _FileDetailRow(label: '完整名称', value: metadata.longTitle!),
              if (metadata.isNew3dsOnly)
                const _FileDetailRow(
                  label: '机型要求',
                  value: '仅支持 New Nintendo 3DS',
                ),
              if (!metadata.hasSmdh)
                const _FileDetailNotice(
                  text: '此 CIA 没有包含 SMDH，因此无法显示软件名称、发行者、地区和图标。',
                ),
              if (metadata.metaReadError?.isNotEmpty == true)
                _FileDetailNotice(
                  text: 'Title ID 和版本已读取；图标信息不可用：${metadata.metaReadError}',
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FileDetailRow extends StatelessWidget {
  const _FileDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          child: Text(label, style: TextStyle(color: context.mutedColor)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _FileDetailNotice extends StatelessWidget {
  const _FileDetailNotice({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: TextStyle(color: color, height: 1.4)),
    );
  }
}

class _SendConfirmation extends StatelessWidget {
  const _SendConfirmation({
    required this.controller,
    required this.onSend,
    required this.onQr,
  });

  final TransferController controller;
  final Future<void> Function() onSend;
  final Future<void> Function() onQr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = controller.selectedDevice;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          theme.colorScheme.primary.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.11 : 0.06,
          ),
          theme.colorScheme.surface,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          final summary = Row(
            children: [
              Container(
                width: 54,
                height: 54,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Nintendo3dsGlyph(
                  size: 34,
                  bodyColor: theme.colorScheme.onSurface,
                  screenColor: AppColors.cyan,
                  detailColor: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '准备发送到 ${device?.name ?? 'Nintendo 3DS'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${controller.files.length} 个文件 · ${formatBytes(controller.selectedBytes)} · ${device?.ip ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.mutedColor,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PrimarySendButton(onTap: onSend),
                    const SizedBox(height: 9),
                    OutlinedButton.icon(
                      onPressed: () => onQr(),
                      icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                      label: const Text('改用二维码安装'),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => onQr(),
                      icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                      label: const Text('二维码'),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 270,
                      child: _PrimarySendButton(onTap: onSend),
                    ),
                  ],
                );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [summary, const SizedBox(height: 17), actions],
            );
          }
          return Row(
            children: [
              Expanded(child: summary),
              const SizedBox(width: 18),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _PrimarySendButton extends StatelessWidget {
  const _PrimarySendButton({required this.onTap});

  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    return Semantics(
      button: true,
      label: '发送到 Nintendo 3DS',
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: Ink(
          height: 56,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF4F67F1), Color(0xFF35BFA8)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: AppColors.cyan.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: InkWell(
            key: const Key('primary-send-button'),
            onTap: () => onTap(),
            borderRadius: radius,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.send_rounded, color: Colors.white, size: 21),
                  SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      '发送到 3DS',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FlowProgress extends StatelessWidget {
  const _FlowProgress({required this.stage});

  final _FlowStage stage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceDone = stage == _FlowStage.files;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 340;
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FlowNode(
                number: 1,
                label: '选择 3DS',
                active: stage == _FlowStage.device,
                done: deviceDone,
                compact: compact,
              ),
              Container(
                width: compact ? 24 : 46,
                height: 1.5,
                margin: EdgeInsets.symmetric(horizontal: compact ? 5 : 9),
                color: deviceDone
                    ? AppColors.success
                    : theme.colorScheme.outline,
              ),
              _FlowNode(
                number: 2,
                label: '选择文件并发送',
                active: stage == _FlowStage.files,
                done: false,
                compact: compact,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FlowNode extends StatelessWidget {
  const _FlowNode({
    required this.number,
    required this.label,
    required this.active,
    required this.done,
    this.compact = false,
  });

  final int number;
  final String label;
  final bool active;
  final bool done;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = done ? AppColors.success : theme.colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: compact ? 24 : 26,
          height: compact ? 24 : 26,
          decoration: BoxDecoration(
            color: done
                ? AppColors.success
                : active
                ? color.withValues(alpha: 0.14)
                : context.softSurface,
            shape: BoxShape.circle,
            border: Border.all(
              color: active || done ? color : theme.colorScheme.outline,
            ),
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                : Text(
                    '$number',
                    style: TextStyle(
                      color: active ? color : context.mutedColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
          ),
        ),
        SizedBox(width: compact ? 5 : 7),
        Text(
          label,
          style: TextStyle(
            color: active || done
                ? theme.colorScheme.onSurface
                : context.mutedColor,
            fontSize: compact ? 11 : 12,
            fontWeight: active || done ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _MiniBadge extends StatelessWidget {
  const _MiniBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.secondary,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

extension _ThemeContext on BuildContext {
  Color get mutedColor => Theme.of(this).brightness == Brightness.dark
      ? AppColors.darkMuted
      : AppColors.muted;

  Color get softSurface => Theme.of(this).brightness == Brightness.dark
      ? AppColors.darkSurfaceHigh
      : const Color(0xFFF3F5FA);
}
