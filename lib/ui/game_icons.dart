import 'package:flutter/material.dart';

import '../app_theme.dart';

class GameBridgeLogo extends StatelessWidget {
  const GameBridgeLogo({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.18),
      decoration: BoxDecoration(
        color: AppColors.blue,
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      child: const Nintendo3dsGlyph(
        bodyColor: Colors.white,
        screenColor: Colors.white,
        detailColor: Colors.white,
      ),
    );
  }
}

/// A compact front-view 3DS glyph.
///
/// Its proportions follow the public Simple Icons Nintendo 3DS artwork while
/// the reduced, stroke-based rendering stays legible at application-icon size.
class Nintendo3dsGlyph extends StatelessWidget {
  const Nintendo3dsGlyph({
    super.key,
    this.size = 40,
    this.bodyColor = AppColors.ink,
    this.screenColor = AppColors.cyan,
    this.detailColor = AppColors.blue,
  });

  final double size;
  final Color bodyColor;
  final Color screenColor;
  final Color detailColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Nintendo 3DS',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _Nintendo3dsPainter(
            bodyColor: bodyColor,
            screenColor: screenColor,
            detailColor: detailColor,
          ),
        ),
      ),
    );
  }
}

class _Nintendo3dsPainter extends CustomPainter {
  const _Nintendo3dsPainter({
    required this.bodyColor,
    required this.screenColor,
    required this.detailColor,
  });

  final Color bodyColor;
  final Color screenColor;
  final Color detailColor;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.save();
    canvas.translate(
      (size.width - 24 * scale) / 2,
      (size.height - 24 * scale) / 2,
    );
    canvas.scale(scale);

    final shell = Paint()
      ..color = bodyColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final screen = Paint()
      ..color = screenColor.withValues(alpha: 0.92)
      ..style = PaintingStyle.fill;
    final controls = Paint()
      ..color = detailColor
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0.75, 0.75, 22.5, 22.5),
        const Radius.circular(2.05),
      ),
      shell,
    );
    canvas.drawLine(
      const Offset(0.85, 11.65),
      const Offset(23.15, 11.65),
      shell,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(5.9, 3.1, 12.1, 6.7),
        const Radius.circular(0.65),
      ),
      screen,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(7.65, 14.65, 8.7, 6.25),
        const Radius.circular(0.55),
      ),
      screen,
    );

    canvas.drawCircle(const Offset(4.2, 16.6), 1.6, controls);
    for (final point in const [
      Offset(19.8, 15.2),
      Offset(21.25, 16.65),
      Offset(18.35, 16.65),
      Offset(19.8, 18.1),
    ]) {
      canvas.drawCircle(point, 0.63, controls);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _Nintendo3dsPainter oldDelegate) =>
      oldDelegate.bodyColor != bodyColor ||
      oldDelegate.screenColor != screenColor ||
      oldDelegate.detailColor != detailColor;
}
