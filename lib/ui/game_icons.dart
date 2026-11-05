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
      padding: EdgeInsets.all(size * 0.17),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.blue, AppColors.cyan],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: const Nintendo3dsGlyph(
        bodyColor: Colors.white,
        screenColor: Color(0xFF5169C7),
        detailColor: Colors.white,
      ),
    );
  }
}

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

class CiaCartridgeGlyph extends StatelessWidget {
  const CiaCartridgeGlyph({
    super.key,
    this.size = 40,
    this.bodyColor = AppColors.blue,
    this.labelColor = Colors.white,
  });

  final double size;
  final Color bodyColor;
  final Color labelColor;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'CIA 安装文件',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _CiaCartridgePainter(
            bodyColor: bodyColor,
            labelColor: labelColor,
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
    final width = size.width;
    final height = size.height;
    final body = Paint()
      ..color = bodyColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final screen = Paint()
      ..color = screenColor
      ..style = PaintingStyle.fill;
    final detail = Paint()
      ..color = detailColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * 0.055
      ..strokeCap = StrokeCap.round;

    final top = RRect.fromRectAndRadius(
      Rect.fromLTWH(width * 0.17, height * 0.05, width * 0.66, height * 0.37),
      Radius.circular(width * 0.08),
    );
    final bottom = RRect.fromRectAndRadius(
      Rect.fromLTWH(width * 0.10, height * 0.53, width * 0.80, height * 0.40),
      Radius.circular(width * 0.09),
    );
    canvas.drawRRect(top, body);
    canvas.drawRRect(bottom, body);
    canvas.drawLine(
      Offset(width * 0.27, height * 0.48),
      Offset(width * 0.73, height * 0.48),
      body,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(width * 0.29, height * 0.14, width * 0.42, height * 0.19),
        Radius.circular(width * 0.025),
      ),
      screen,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(width * 0.37, height * 0.61, width * 0.27, height * 0.18),
        Radius.circular(width * 0.025),
      ),
      screen,
    );

    canvas.drawCircle(
      Offset(width * 0.23, height * 0.68),
      width * 0.065,
      detail,
    );
    canvas.drawLine(
      Offset(width * 0.20, height * 0.83),
      Offset(width * 0.28, height * 0.83),
      detail,
    );
    canvas.drawLine(
      Offset(width * 0.24, height * 0.79),
      Offset(width * 0.24, height * 0.87),
      detail,
    );
    canvas.drawCircle(
      Offset(width * 0.76, height * 0.67),
      width * 0.023,
      detail,
    );
    canvas.drawCircle(
      Offset(width * 0.82, height * 0.72),
      width * 0.023,
      detail,
    );
    canvas.drawCircle(
      Offset(width * 0.70, height * 0.72),
      width * 0.023,
      detail,
    );
    canvas.drawCircle(
      Offset(width * 0.76, height * 0.77),
      width * 0.023,
      detail,
    );
  }

  @override
  bool shouldRepaint(covariant _Nintendo3dsPainter oldDelegate) =>
      oldDelegate.bodyColor != bodyColor ||
      oldDelegate.screenColor != screenColor ||
      oldDelegate.detailColor != detailColor;
}

class _CiaCartridgePainter extends CustomPainter {
  const _CiaCartridgePainter({
    required this.bodyColor,
    required this.labelColor,
  });

  final Color bodyColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final cartridge = Path()
      ..moveTo(width * 0.24, height * 0.08)
      ..lineTo(width * 0.40, height * 0.08)
      ..lineTo(width * 0.43, height * 0.15)
      ..lineTo(width * 0.65, height * 0.15)
      ..lineTo(width * 0.68, height * 0.08)
      ..lineTo(width * 0.75, height * 0.08)
      ..quadraticBezierTo(
        width * 0.86,
        height * 0.08,
        width * 0.86,
        height * 0.20,
      )
      ..lineTo(width * 0.86, height * 0.78)
      ..lineTo(width * 0.76, height * 0.92)
      ..lineTo(width * 0.24, height * 0.92)
      ..lineTo(width * 0.14, height * 0.78)
      ..lineTo(width * 0.14, height * 0.20)
      ..quadraticBezierTo(
        width * 0.14,
        height * 0.08,
        width * 0.24,
        height * 0.08,
      )
      ..close();
    canvas.drawPath(cartridge, Paint()..color = bodyColor);

    final labelRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(width * 0.23, height * 0.29, width * 0.54, height * 0.42),
      Radius.circular(width * 0.05),
    );
    canvas.drawRRect(
      labelRect,
      Paint()..color = labelColor.withValues(alpha: 0.96),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          width * 0.28,
          height * 0.34,
          width * 0.035,
          height * 0.14,
        ),
        Radius.circular(width * 0.012),
      ),
      Paint()..color = const Color(0xFFFA6581),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          width * 0.33,
          height * 0.34,
          width * 0.035,
          height * 0.14,
        ),
        Radius.circular(width * 0.012),
      ),
      Paint()..color = const Color(0xFF36CBB0),
    );
    final text = TextPainter(
      text: TextSpan(
        text: 'CIA',
        style: TextStyle(
          color: bodyColor,
          fontSize: width * 0.18,
          fontWeight: FontWeight.w900,
          letterSpacing: width * 0.015,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset(width * 0.40, height * 0.43));

    final contact = Paint()
      ..color = const Color(0xFFFFD25F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * 0.035
      ..strokeCap = StrokeCap.round;
    for (final x in const [0.32, 0.41, 0.50, 0.59, 0.68]) {
      canvas.drawLine(
        Offset(width * x, height * 0.79),
        Offset(width * x, height * 0.86),
        contact,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CiaCartridgePainter oldDelegate) =>
      oldDelegate.bodyColor != bodyColor ||
      oldDelegate.labelColor != labelColor;
}
