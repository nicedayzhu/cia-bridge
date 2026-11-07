import 'package:cia_bridge/app_theme.dart';
import 'package:cia_bridge/core/models.dart';
import 'package:cia_bridge/transfer_controller.dart';
import 'package:cia_bridge/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sizes = [
    Size(320, 720),
    Size(600, 800),
    Size(899, 700),
    Size(900, 700),
    Size(1024, 700),
  ];

  for (final size in sizes) {
    testWidgets('send page has no overflow at ${size.width.toInt()} px', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = _readyController();
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(),
          darkTheme: buildTheme(brightness: Brightness.dark),
          home: HomePage(controller: controller, initializeController: false),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('primary-send-button')), findsOneWidget);
      expect(find.byKey(const Key('device-capability-notice')), findsOneWidget);
      expect(find.text('当前不支持 LayeredFS 补丁'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}

TransferController _readyController() {
  const device = NearbyDevice(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01');
  return TransferController()
    ..files.add(
      const ShareFile(id: 'preview-cia', name: '3DShell.cia', size: 1600000),
    )
    ..addresses = ['192.168.0.104']
    ..selectedAddress = '192.168.0.104'
    ..devices = [device]
    ..selectedDevice = device
    ..targetIp = device.ip
    ..mode = TransferMode.push
    ..discoveryStatus = '发现 1 台 Nintendo 设备';
}
