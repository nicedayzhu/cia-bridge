import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import '../core/models.dart';
import '../transfer_controller.dart';
import 'game_icons.dart';
import 'transfer_panel.dart';

const _appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '开发构建');

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

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _autoRefreshTimer;
  bool _isForeground = true;
  late _FlowStage _stage;
  late final TextEditingController _httpPortController;

  TransferController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _httpPortController = TextEditingController(text: '${controller.httpPort}');
    _stage =
        controller.session != null ||
            (controller.selectedDevice != null &&
                (controller.selectedFiles.isNotEmpty ||
                    controller.buildingPatch))
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
    _httpPortController.text = '${controller.httpPort}';
    _stage =
        controller.session != null ||
            (controller.selectedDevice != null &&
                (controller.selectedFiles.isNotEmpty ||
                    controller.buildingPatch))
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
    _httpPortController.dispose();
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
      key: _scaffoldKey,
      drawerScrimColor: Colors.black.withValues(alpha: 0.58),
      endDrawer: _SettingsSideSheet(
        controller: controller,
        portController: _httpPortController,
        onUsageGuide: () => _showUsageGuide(context),
        onAbout: () => _showAbout(context),
      ),
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
      if (controller.selectedFiles.isEmpty) {
        throw StateError('请先选择要发送的安装文件或 LayeredFS 补丁');
      }
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
    final patchPort = TextEditingController(text: '5002');
    var supportsPatch = false;
    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('手动添加 3DS'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '在 3DS 的 FBI 中打开 “Remote Install / Receive URLs over the network”，然后输入屏幕显示的 IP。',
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
                      labelText: '安装文件端口',
                      helperText: '默认 5000',
                      prefixIcon: Icon(Icons.lan_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: context.softSurface,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: SwitchListTile(
                      contentPadding: const EdgeInsets.fromLTRB(14, 3, 8, 3),
                      value: supportsPatch,
                      onChanged: (value) =>
                          setDialogState(() => supportsPatch = value),
                      title: const Text(
                        'FBI CIA Bridge 补丁接收',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: const Text('仅在 3DS 已安装 CIA Bridge 版 FBI 时开启'),
                    ),
                  ),
                  if (supportsPatch) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: patchPort,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'LayeredFS 补丁端口',
                        helperText: '默认 5002',
                        prefixIcon: Icon(Icons.extension_outlined),
                      ),
                    ),
                  ],
                ],
              ),
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
      ),
    );
    if (added == true) {
      try {
        controller.addManualDevice(
          ip.text,
          port: int.tryParse(port.text) ?? 5000,
          patchPort: supportsPatch
              ? int.tryParse(patchPort.text) ?? 5002
              : null,
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
    patchPort.dispose();
  }

  void _showNetworkSettings() {
    final port = '${controller.httpPort}';
    if (_httpPortController.text != port) {
      _httpPortController.text = port;
    }
    unawaited(controller.refreshAddresses());
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _showUsageGuide(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使用方法'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _UsageStep(
                  number: 1,
                  title: '准备网络与 FBI',
                  detail: '设备在同一局域网，并在 FBI → Remote Install 中打开 Receive URLs over the network。',
                ),
                _UsageStep(
                  number: 2,
                  title: '选择 3DS',
                  detail: '等待自动发现；如果没有显示，可重新扫描或手动输入 IP。',
                ),
                _UsageStep(
                  number: 3,
                  title: '选择要发送的内容',
                  detail: '可选择 CIA 安装文件，或 LayeredFS 补丁目录。',
                ),
                _UsageStep(
                  number: 4,
                  title: '发送并在 3DS 确认',
                  detail: '发送后根据 3DS 上的提示确认，保持 CIA Bridge 打开直至完成。',
                  last: true,
                ),
                SizedBox(height: 6),
                _GuideNote(),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'CIA Bridge',
      applicationVersion: _appVersion,
      applicationIcon: const GameBridgeLogo(size: 48),
      applicationLegalese: 'MIT License',
      children: const [
        Text('把安装文件和 LayeredFS 补丁从电脑或手机发送到 Nintendo 3DS。'),
        SizedBox(height: 10),
        Text('第三方组件许可证详见程序随附的 THIRD_PARTY_NOTICES.md。'),
      ],
    );
  }

  void _showError(Object error) {
    if (!mounted) return;
    final message = error.toString().replaceFirst(
      RegExp(
        r'^(StateError|ArgumentError|FormatException|FileSystemException|UnsupportedError|SocketException|PlatformException)[:(]\s*',
      ),
      '',
    );
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(child: Text(message)),
            ],
          ),
          action: SnackBarAction(
            label: '知道了',
            textColor: Colors.white,
            onPressed: messenger.hideCurrentSnackBar,
          ),
        ),
      );
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
        child: SizedBox(
          height: 64,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const GameBridgeLogo(size: 38),
                    const SizedBox(width: 12),
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
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.15,
                                ),
                              ),
                              if (constraints.maxWidth > 220)
                                Text(
                                  '把 CIA 送到你的 Nintendo 3DS',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.mutedColor,
                                    fontSize: 11,
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
                    IconButton.filledTonal(
                      key: const Key('settings-button'),
                      tooltip: '设置',
                      onPressed: onNetworkSettings,
                      icon: const Icon(Icons.tune_rounded, size: 20),
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

class _SettingsSideSheet extends StatelessWidget {
  const _SettingsSideSheet({
    required this.controller,
    required this.portController,
    required this.onUsageGuide,
    required this.onAbout,
  });

  final TransferController controller;
  final TextEditingController portController;
  final VoidCallback onUsageGuide;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final compact = screenWidth < 600;
    final panelWidth = compact ? screenWidth * 0.92 : 420.0;
    final theme = Theme.of(context);

    return Drawer(
      key: const Key('settings-side-sheet'),
      width: panelWidth,
      elevation: 24,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(left: Radius.circular(24)),
      ),
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '设置',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('settings-close-button'),
                    tooltip: '关闭设置',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final selected =
                      controller.addresses.contains(controller.selectedAddress)
                      ? controller.selectedAddress
                      : null;
                  return SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 20 : 24,
                      20,
                      compact ? 20 : 24,
                      28,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '网络',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
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
                        const SizedBox(height: 10),
                        TextField(
                          controller: portController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'HTTP 端口',
                            helperText: '默认 8080；冲突时自动回退',
                            prefixIcon: Icon(Icons.http_rounded),
                          ),
                          onChanged: (value) =>
                              controller.httpPort = int.tryParse(value) ?? 8080,
                        ),
                        const Divider(height: 34),
                        ListTile(
                          key: const Key('usage-guide-tile'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: const Icon(Icons.help_outline_rounded),
                          title: const Text('使用方法'),
                          subtitle: const Text('查看连接、选择和发送流程'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          onTap: onUsageGuide,
                        ),
                        const SizedBox(height: 4),
                        ListTile(
                          key: const Key('about-app-tile'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: const Icon(Icons.info_outline_rounded),
                          title: const Text('版本与许可'),
                          subtitle: const Text('CIA Bridge · $_appVersion'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          onTap: onAbout,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageStep extends StatelessWidget {
  const _UsageStep({
    required this.number,
    required this.title,
    required this.detail,
    this.last = false,
  });

  final int number;
  final String title;
  final String detail;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$number',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (!last)
              Container(
                width: 1,
                height: 42,
                color: theme.colorScheme.outlineVariant,
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.mutedColor,
                    height: 1.45,
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

class _GuideNote extends StatelessWidget {
  const _GuideNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '文件只在当前局域网传输。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
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
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 42),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _FlowProgress(stage: _FlowStage.device),
                const SizedBox(height: 28),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Nintendo3dsGlyph(
                        size: 30,
                        bodyColor: theme.colorScheme.onPrimaryContainer,
                        screenColor: theme.colorScheme.primary,
                        detailColor: theme.colorScheme.secondary,
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '选择你的 Nintendo 3DS',
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '在 3DS 上打开 FBI / Remote Install / Receive URLs over the network',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: context.mutedColor,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _DiscoveryBar(
                  controller: controller,
                  onManualDevice: onManualDevice,
                ),
                const SizedBox(height: 12),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
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
                    : const Icon(Icons.refresh_rounded, size: 18),
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
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Nintendo3dsGlyph(
                  size: 28,
                  bodyColor: theme.colorScheme.onPrimaryContainer,
                  screenColor: theme.colorScheme.primary,
                  detailColor: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(width: 13),
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
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (device.isManual) ...[
                          const SizedBox(width: 8),
                          _MiniBadge(label: '手动'),
                        ] else if (device.isProtocolDiscovered) ...[
                          const SizedBox(width: 8),
                          _MiniBadge(label: '已就绪'),
                        ] else if (device.isCandidate) ...[
                          const SizedBox(width: 8),
                          _MiniBadge(label: '候选'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      device.isProtocolDiscovered
                          ? device.supportsPatch
                                ? '${device.ip} · FBI CIA Bridge'
                                      '${device.receiverVersion == null ? '' : ' v${device.receiverVersion}'}'
                                      ' · 可接收安装文件与汉化补丁'
                                : '${device.ip} · 普通 FBI，仅支持 CIA 安装'
                          : device.isCandidate
                          ? '${device.ip} · 请与 FBI 屏幕上的 IP 核对'
                          : device.ip,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: context.mutedColor, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: Key('select-device-button-${device.ip}'),
                onPressed: onTap,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('选择'),
                    SizedBox(width: 2),
                    Icon(Icons.chevron_right_rounded, size: 18),
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
                  enabled:
                      !controller.serverRunning && !controller.buildingPatch,
                  onChangeDevice: onChangeDevice,
                ),
                if (!hasSession && controller.selectedDevice != null) ...[
                  const SizedBox(height: 12),
                  _DeviceCapabilityNotice(device: controller.selectedDevice!),
                ],
                const SizedBox(height: 28),
                if (hasSession)
                  TransferPanel(
                    controller: controller,
                    onStop: onStop,
                    onRetry: onSend,
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
                  if (controller.selectedFiles.isNotEmpty) ...[
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Nintendo3dsGlyph(
              size: 28,
              bodyColor: theme.colorScheme.onPrimaryContainer,
              screenColor: theme.colorScheme.primary,
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
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  device?.ip ?? '未选择设备',
                  style: TextStyle(color: context.mutedColor, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: enabled ? onChangeDevice : null,
            child: const Text('更换设备'),
          ),
        ],
      ),
    );
  }
}

class _DeviceCapabilityNotice extends StatelessWidget {
  const _DeviceCapabilityNotice({required this.device});

  final NearbyDevice device;

  @override
  Widget build(BuildContext context) {
    final supported = device.supportsPatch;
    final color = supported ? AppColors.success : AppColors.warning;
    return Container(
      key: const Key('device-capability-notice'),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            supported ? Icons.verified_rounded : Icons.info_outline_rounded,
            color: color,
            size: 22,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  supported ? '已检测到 FBI CIA Bridge' : '当前不支持 LayeredFS 补丁',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  supported
                      ? '可发送 CIA 安装文件和 LayeredFS 补丁；补丁会自动使用快速增量传输。'
                      : '仍可发送 CIA、TIK、CETK、3DSX 安装文件；如需发送 LayeredFS 补丁，'
                            '请先在 3DS 上安装并打开 FBI CIA Bridge。',
                  style: TextStyle(
                    color: context.mutedColor,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
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
          '选择要发送的文件',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.35,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          controller.selectedDevice?.supportsPatch == true
              ? '自动识别 CIA、TIK、CETK、3DSX 安装文件和 LayeredFS 补丁 ZIP'
              : '当前接收端仅支持 CIA、TIK、CETK、3DSX 安装文件',
          style: TextStyle(color: context.mutedColor, fontSize: 12.5),
        ),
        const SizedBox(height: 14),
        Card(
          child: controller.buildingPatch
              ? _PatchPreparingState(status: controller.status)
              : controller.selectedFiles.isEmpty
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
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.folder_zip_outlined,
              color: theme.colorScheme.onSecondaryContainer,
              size: 28,
            ),
          );
          final copy = Column(
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Text(
                '选择文件，软件会自动识别',
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '安装文件会由 3DS 接收端安装；含 luma/titles/<Title ID>/romfs 的 ZIP 会自动作为汉化补丁处理。',
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.mutedColor,
                  height: 1.35,
                ),
              ),
            ],
          );
          final buttons = Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: compact ? WrapAlignment.center : WrapAlignment.end,
            children: [
              FilledButton.icon(
                onPressed: () => onPickFiles(),
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('选择文件'),
              ),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: icon),
                const SizedBox(height: 16),
                copy,
                const SizedBox(height: 20),
                buttons,
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: 16),
              Expanded(child: copy),
              const SizedBox(width: 18),
              buttons,
            ],
          );
        },
      ),
    );
  }
}

class _PatchPreparingState extends StatelessWidget {
  const _PatchPreparingState({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const Key('patch-preparing-card'),
      padding: const EdgeInsets.all(22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.folder_zip_outlined,
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '正在准备 LayeredFS 补丁',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 5),
                Text(
                  status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.mutedColor,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  '正在校验并转换文件，请保持应用打开。',
                  style: TextStyle(color: context.mutedColor, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
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
    if (controller.isPatchMode) {
      return _SelectedPatch(controller: controller, onPickFiles: onPickFiles);
    }
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
              itemCount: controller.selectedFiles.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final file = controller.selectedFiles[index];
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

class _SelectedPatch extends StatelessWidget {
  const _SelectedPatch({required this.controller, required this.onPickFiles});

  final TransferController controller;
  final Future<void> Function() onPickFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final patch = controller.preparedPatch!;
    return Padding(
      key: const Key('patch-ready-card'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondary.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.extension_rounded,
                  color: theme.colorScheme.secondary,
                  size: 28,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _MiniBadge(label: 'LayeredFS 补丁'),
                    const SizedBox(height: 6),
                    Text(
                      controller.patchDisplayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      controller.patchInfoLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.mutedColor,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: controller.clearFiles,
                tooltip: '移除补丁',
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              Text(
                '${patch.fileCount} 个文件',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                formatBytes(patch.rawBytes),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                '来源：${patch.sourceLabel}',
                style: TextStyle(color: context.mutedColor),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.bolt_rounded,
                  color: AppColors.success,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '快速增量安装：3DS 会跳过内容相同的文件，只写入变化内容。',
                    style: TextStyle(
                      color: context.mutedColor,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () => onPickFiles(),
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('重新选择补丁'),
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
    final theme = Theme.of(context);
    final bytes = file.ciaMetadata?.iconPng;
    final fallback = Center(
      child: Icon(
        Icons.description_outlined,
        size: size * 0.46,
        color: theme.colorScheme.secondary,
      ),
    );
    return Container(
      width: size,
      height: size,
      padding: bytes == null ? EdgeInsets.all(size * 0.16) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.13),
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
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          final summary = Row(
            children: [
              Container(
                width: 46,
                height: 46,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Nintendo3dsGlyph(
                  size: 28,
                  bodyColor: theme.colorScheme.onPrimaryContainer,
                  screenColor: theme.colorScheme.primary,
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
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      controller.isPatchMode
                          ? '${controller.patchDisplayName} · '
                                '${controller.preparedPatch!.fileCount} 个文件 · '
                                '${formatBytes(controller.preparedPatch!.rawBytes)} · '
                                '${device?.ip ?? ''}'
                          : '${controller.files.length} 个文件 · ${formatBytes(controller.selectedBytes)} · ${device?.ip ?? ''}',
                      maxLines: controller.isPatchMode ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.mutedColor,
                        fontSize: 11.5,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      controller.isPatchMode
                          ? '请保持 FBI / Remote Install / Receive URLs over the network 打开；'
                                '出现提示后选择 Yes，补丁会直接写入 LayeredFS。'
                          : '请保持 FBI / Remote Install / Receive URLs over the network 打开；'
                                '发送后在 3DS 上确认安装。',
                      maxLines: compact ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.mutedColor,
                        fontSize: 11,
                        height: 1.35,
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
                    _PrimarySendButton(
                      onTap: onSend,
                      label: controller.isPatchMode ? '发送补丁到 3DS' : '发送到 3DS',
                    ),
                    if (!controller.isPatchMode) ...[
                      const SizedBox(height: 9),
                      OutlinedButton.icon(
                        onPressed: () => onQr(),
                        icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                        label: const Text('改用二维码安装'),
                      ),
                    ],
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!controller.isPatchMode) ...[
                      OutlinedButton.icon(
                        onPressed: () => onQr(),
                        icon: const Icon(Icons.qr_code_2_rounded, size: 19),
                        label: const Text('二维码'),
                      ),
                      const SizedBox(width: 10),
                    ],
                    SizedBox(
                      width: 270,
                      child: _PrimarySendButton(
                        onTap: onSend,
                        label: controller.isPatchMode ? '发送补丁到 3DS' : '发送到 3DS',
                      ),
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
  const _PrimarySendButton({required this.onTap, required this.label});

  final Future<void> Function() onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      key: const Key('primary-send-button'),
      onPressed: () => onTap(),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
      icon: const Icon(Icons.send_rounded, size: 20),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class _FlowProgress extends StatelessWidget {
  const _FlowProgress({required this.stage});

  final _FlowStage stage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectingDevice = stage == _FlowStage.device;
    return Semantics(
      label: selectingDevice ? '第 1 步，共 2 步：选择 3DS' : '第 2 步，共 2 步：选择文件并发送',
      child: ExcludeSemantics(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Row(
              children: [
                _FlowStep(
                  number: 1,
                  label: '选择 3DS',
                  active: selectingDevice,
                  complete: !selectingDevice,
                ),
                Expanded(
                  child: Container(
                    height: 2,
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    color: selectingDevice
                        ? theme.colorScheme.outlineVariant
                        : theme.colorScheme.primary,
                  ),
                ),
                _FlowStep(
                  number: 2,
                  label: '选择文件并发送',
                  active: !selectingDevice,
                  complete: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FlowStep extends StatelessWidget {
  const _FlowStep({
    required this.number,
    required this.label,
    required this.active,
    required this.complete,
  });

  final int number;
  final String label;
  final bool active;
  final bool complete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final foreground = active || complete
        ? theme.colorScheme.onPrimary
        : context.mutedColor;
    final background = active || complete
        ? primary
        : theme.colorScheme.surfaceContainerHighest;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: complete
              ? Icon(Icons.check_rounded, size: 17, color: foreground)
              : Text(
                  '$number',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: active || complete
                ? theme.colorScheme.onSurface
                : context.mutedColor,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
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
