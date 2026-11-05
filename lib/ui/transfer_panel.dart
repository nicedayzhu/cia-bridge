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
    required this.onContinue,
    required this.onClear,
    required this.onQrFallback,
  });

  final TransferController controller;
  final Future<void> Function() onStop;
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
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ConsoleBadge(
            screenColor: AppColors.success,
            badgeColor: AppColors.success,
            badgeIcon: Icons.check_rounded,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '本次发送已完成',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
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
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ConsoleBadge(
            screenColor: AppColors.danger,
            badgeColor: AppColors.danger,
            badgeIcon: Icons.priority_high_rounded,
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '没有连接到 FBI',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
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
    final cardColor = theme.brightness == Brightness.dark
        ? AppColors.darkSurfaceHigh
        : AppColors.navy;
    return Container(
      key: ValueKey('transfer-${controller.phase.name}'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (showQr) ...[
            Container(
              width: 126,
              height: 126,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: QrImageView(
                data: session.payload,
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(width: 18),
          ] else ...[
            Container(
              width: 66,
              height: 66,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(19),
              ),
              child: const Nintendo3dsGlyph(
                size: 44,
                bodyColor: Colors.white,
                screenColor: AppColors.cyan,
                detailColor: AppColors.cyan,
              ),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  showQr ? '使用 FBI 扫描二维码' : _activeTitle(controller.phase),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  controller.status,
                  style: const TextStyle(
                    color: Color(0xFFC2D1CC),
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 13),
                LinearProgressIndicator(
                  value: controller.phase == TransferPhase.transferring
                      ? controller.progress
                      : null,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(99),
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                  color: AppColors.mint,
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: () => onStop(),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('停止'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _activeTitle(TransferPhase phase) => switch (phase) {
    TransferPhase.preparing => '正在准备局域网服务',
    TransferPhase.connecting => '正在连接 3DS',
    TransferPhase.waitingForFbi => '等待你在 3DS 上确认',
    TransferPhase.transferring => '正在传输 CIA 文件',
    TransferPhase.hosting => '等待 FBI 扫描二维码',
    _ => '发送到 3DS',
  };

  static Color _muted(ThemeData theme) => theme.brightness == Brightness.dark
      ? AppColors.darkMuted
      : AppColors.muted;
}

class _ConsoleBadge extends StatelessWidget {
  const _ConsoleBadge({
    required this.screenColor,
    required this.badgeColor,
    required this.badgeIcon,
  });

  final Color screenColor;
  final Color badgeColor;
  final IconData badgeIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 66,
          height: 66,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: theme.colorScheme.outline),
          ),
          child: Nintendo3dsGlyph(
            size: 44,
            bodyColor: theme.colorScheme.onSurface,
            screenColor: screenColor,
            detailColor: theme.colorScheme.secondary,
          ),
        ),
        Positioned(
          right: -5,
          bottom: -5,
          child: Container(
            width: 25,
            height: 25,
            decoration: BoxDecoration(
              color: badgeColor,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.surface, width: 2),
            ),
            child: Icon(badgeIcon, color: Colors.white, size: 15),
          ),
        ),
      ],
    );
  }
}
