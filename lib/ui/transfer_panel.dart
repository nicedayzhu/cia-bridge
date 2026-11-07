import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_theme.dart';
import '../core/models.dart';
import '../transfer_controller.dart';
import 'game_icons.dart';

class TransferPanel extends StatelessWidget {
  const TransferPanel({
    super.key,
    required this.controller,
    required this.onStop,
    required this.onRetry,
    required this.onContinue,
    required this.onClear,
    required this.onQrFallback,
  });

  final TransferController controller;
  final Future<void> Function() onStop;
  final Future<void> Function() onRetry;
  final VoidCallback onContinue;
  final VoidCallback onClear;
  final VoidCallback onQrFallback;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      child: switch (controller.phase) {
        TransferPhase.complete => _buildComplete(context),
        TransferPhase.error => _buildError(context),
        _ => _buildActive(context),
      },
    );
  }

  Widget _buildComplete(BuildContext context) {
    final theme = Theme.of(context);
    final background = Color.alphaBlend(
      AppColors.success.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.16 : 0.08,
      ),
      theme.colorScheme.surface,
    );
    return Container(
      key: const ValueKey('transfer-complete'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelLeading.status(
            color: AppColors.success,
            icon: Icons.check_rounded,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本次发送已完成',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  controller.status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _muted(theme),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 13),
                const LinearProgressIndicator(
                  value: 1,
                  minHeight: 6,
                  borderRadius: BorderRadius.all(Radius.circular(99)),
                  backgroundColor: Color(0x3330AF7A),
                  color: AppColors.success,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onContinue,
                      icon: const Icon(Icons.replay_rounded, size: 18),
                      label: const Text('继续发送当前文件'),
                    ),
                    FilledButton.icon(
                      onPressed: onClear,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.done_all_rounded, size: 18),
                      label: const Text('完成并清空'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    final background = Color.alphaBlend(
      AppColors.danger.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.16 : 0.07,
      ),
      theme.colorScheme.surface,
    );
    return Container(
      key: const ValueKey('transfer-error'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelLeading.status(
            color: AppColors.danger,
            icon: Icons.priority_high_rounded,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '未连接到 3DS 接收端',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  controller.status,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _muted(theme),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('retry-send-button'),
                      onPressed: () => onRetry(),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重新连接'),
                    ),
                    if (!controller.isPatchMode)
                      OutlinedButton.icon(
                        onPressed: onQrFallback,
                        icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                        label: const Text('改用二维码'),
                      ),
                    TextButton.icon(
                      onPressed: () => onStop(),
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('停止共享'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActive(BuildContext context) {
    final theme = Theme.of(context);
    final session = controller.session;
    final showQr = controller.mode == TransferMode.qr && session != null;
    final isDark = theme.brightness == Brightness.dark;
    final accent = isDark ? AppColors.mint : theme.colorScheme.primary;
    final baseColor = isDark
        ? AppColors.darkSurfaceHigh
        : theme.colorScheme.surfaceContainerLow;
    final cardColor = Color.alphaBlend(
      accent.withValues(alpha: isDark ? 0.07 : 0.055),
      baseColor,
    );
    final borderColor = accent.withValues(alpha: isDark ? 0.28 : 0.18);
    final title = showQr ? '使用 3DS 扫描二维码' : _activeTitle(controller);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final leading = showQr
            ? Container(
                width: 126,
                height: 126,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: borderColor),
                ),
                child: QrImageView(
                  data: session.payload,
                  padding: EdgeInsets.zero,
                ),
              )
            : _PanelLeading.console(color: accent);
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _TransferActivityIndicator(
                  key: const Key('transfer-activity-indicator'),
                  color: accent,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              controller.status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _muted(theme),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            if (controller.phase == TransferPhase.transferring &&
                controller.totalBytes > 0)
              _TransferProgress(controller: controller, accent: accent)
            else
              LinearProgressIndicator(
                minHeight: 7,
                borderRadius: BorderRadius.circular(99),
                backgroundColor: theme.colorScheme.onSurface.withValues(
                  alpha: 0.1,
                ),
                color: accent,
              ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => onStop(),
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: const Text('停止传输'),
            ),
          ],
        );

        return Container(
          key: ValueKey('transfer-${controller.phase.name}'),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: leading),
                    const SizedBox(height: 16),
                    details,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leading,
                    const SizedBox(width: 18),
                    Expanded(child: details),
                  ],
                ),
        );
      },
    );
  }

  static String _activeTitle(TransferController controller) =>
      switch (controller.phase) {
        TransferPhase.preparing => '正在准备局域网服务',
        TransferPhase.connecting => '正在连接 3DS',
        TransferPhase.waitingForFbi => '等待你在 3DS 上确认',
        TransferPhase.transferring when controller.transferActive =>
          '正在传输到 3DS',
        TransferPhase.transferring when controller.progress == 1 =>
          '传输完成，等待 3DS 处理',
        TransferPhase.transferring => '等待 3DS 继续接收',
        TransferPhase.hosting => '等待 3DS 扫描二维码',
        _ => '发送到 3DS',
      };

  static Color _muted(ThemeData theme) => theme.brightness == Brightness.dark
      ? AppColors.darkMuted
      : AppColors.muted;
}

class _TransferProgress extends StatefulWidget {
  const _TransferProgress({required this.controller, required this.accent});

  final TransferController controller;
  final Color accent;

  @override
  State<_TransferProgress> createState() => _TransferProgressState();
}

class _TransferProgressState extends State<_TransferProgress> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _TransferProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    if (!widget.controller.transferActive) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final value = controller.progress ?? 0;
    final percent = (value * 100).round().clamp(0, 100);
    final remaining = controller.estimatedRemaining;
    final isWaiting = !controller.transferActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '已传输 ${formatBytes(controller.bytesServed)} / '
                '${formatBytes(controller.totalBytes)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _panelMuted(theme),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$percent%',
              key: const Key('transfer-percent'),
              style: theme.textTheme.labelLarge?.copyWith(
                color: widget.accent,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: value,
          minHeight: 8,
          borderRadius: BorderRadius.circular(99),
          backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.1),
          color: widget.accent,
        ),
        const SizedBox(height: 11),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: isWaiting
              ? [
                  _TransferMetric(
                    icon: Icons.hourglass_top_rounded,
                    label: '等待 3DS 处理',
                    color: widget.accent,
                  ),
                ]
              : [
                  _TransferMetric(
                    key: const Key('transfer-speed'),
                    icon: Icons.speed_rounded,
                    label: controller.transferBytesPerSecond > 0
                        ? '${formatBytes(controller.transferBytesPerSecond.round())}/s'
                        : '-- MB/s',
                    color: widget.accent,
                  ),
                  _TransferMetric(
                    key: const Key('transfer-eta'),
                    icon: Icons.schedule_rounded,
                    label: remaining == null || remaining == Duration.zero
                        ? 'ETA --:--'
                        : 'ETA ${_formatRemaining(remaining)}',
                    color: widget.accent,
                  ),
                ],
        ),
      ],
    );
  }

  static String _formatRemaining(Duration value) {
    final seconds = value.inSeconds.clamp(1, 359999);
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSeconds = seconds % 60;
    final tail =
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
    return hours == 0 ? tail : '${hours.toString().padLeft(2, '0')}:$tail';
  }
}

class _TransferMetric extends StatelessWidget {
  const _TransferMetric({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _TransferActivityIndicator extends StatefulWidget {
  const _TransferActivityIndicator({super.key, required this.color});

  final Color color;

  @override
  State<_TransferActivityIndicator> createState() =>
      _TransferActivityIndicatorState();
}

class _TransferActivityIndicatorState extends State<_TransferActivityIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '传输进行中',
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => SizedBox(
          width: 25,
          height: 15,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (index) {
              final phase = (_controller.value * 3 - index) % 3;
              final pulse = phase < 1
                  ? phase
                  : phase < 2
                  ? 2 - phase
                  : 0.0;
              return Container(
                width: 6,
                height: 6 + (pulse * 8),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.4 + pulse * 0.6),
                  borderRadius: BorderRadius.circular(99),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

Color _panelMuted(ThemeData theme) =>
    theme.brightness == Brightness.dark ? AppColors.darkMuted : AppColors.muted;

class _PanelLeading extends StatelessWidget {
  const _PanelLeading.console({required this.color}) : icon = null;

  const _PanelLeading.status({required this.color, required this.icon});

  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 56,
      height: 56,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.17 : 0.12,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: icon == null
          ? Nintendo3dsGlyph(
              size: 34,
              bodyColor: theme.colorScheme.onSurface,
              screenColor: color,
              detailColor: color,
            )
          : Icon(icon, color: color, size: 30),
    );
  }
}
