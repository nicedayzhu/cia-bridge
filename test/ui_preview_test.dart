import 'package:cia_bridge/main.dart';
import 'package:cia_bridge/app_theme.dart';
import 'package:cia_bridge/core/models.dart';
import 'package:cia_bridge/transfer_controller.dart';
import 'package:cia_bridge/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() async {
    final appFontLoader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC-CIABridge.ttf'));
    final iconFontLoader = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([appFontLoader.load(), iconFontLoader.load()]);
  });

  testWidgets('renders the desktop send page', (tester) async {
    tester.view.physicalSize = const Size(1166, 742);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const CiaBridgeApp());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('refresh-devices-button')), findsOneWidget);
    expect(find.text('选择你的 Nintendo 3DS'), findsOneWidget);
    expect(find.byKey(const Key('primary-send-button')), findsNothing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/home_page_windows.png'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('completed transfer has a clear result state', (tester) async {
    tester.view.physicalSize = const Size(1166, 742);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TransferController()
      ..files.add(
        const ShareFile(id: 'preview-cia', name: '3DShell.cia', size: 1600000),
      )
      ..phase = TransferPhase.complete
      ..status = 'FBI 已完成本次请求，局域网服务已停止'
      ..session = const HostingSession(
        urls: ['http://192.168.0.2:8080/3DShell.cia'],
        port: 8080,
        totalBytes: 1600000,
        usedFallbackPort: false,
      );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('本次发送已完成'), findsOneWidget);
    expect(find.text('继续发送当前文件'), findsOneWidget);
    expect(find.text('完成并清空'), findsOneWidget);
    expect(find.text('停止'), findsNothing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/transfer_complete_windows.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('ready desktop layout makes send action prominent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1166, 742);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = _readyController();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brightness: Brightness.dark),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('primary-send-button')), findsOneWidget);
    expect(find.text('发送到 3DS'), findsOneWidget);
    expect(find.text('192.168.0.103'), findsWidgets);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/send_ready_windows_dark.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('ready Android layout keeps the primary action visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = _readyController();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('primary-send-button')), findsOneWidget);
    expect(find.text('改用二维码安装'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/send_ready_android.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('compact Android layout starts with device discovery', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TransferController()
      ..addresses = ['192.168.0.104']
      ..selectedAddress = '192.168.0.104'
      ..discoveryStatus = '暂未发现 Nintendo 设备';
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('选择你的 Nintendo 3DS'), findsOneWidget);
    expect(find.byKey(const Key('primary-send-button')), findsNothing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/send_empty_android_compact.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('selecting a device advances to the file stage', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const device = NearbyDevice(ip: '192.168.0.103', mac: '40:D2:8A:00:00:01');
    final controller = TransferController()
      ..addresses = ['192.168.0.104']
      ..selectedAddress = '192.168.0.104'
      ..devices = [device]
      ..discoveryStatus = '发现 1 台 Nintendo 设备';
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );

    expect(find.text('选择你的 Nintendo 3DS'), findsOneWidget);
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();

    expect(find.text('选择要安装的文件'), findsOneWidget);
    expect(find.text('更换设备'), findsOneWidget);
    expect(find.byKey(const Key('primary-send-button')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Android candidate is clearly labeled before selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const candidate = NearbyDevice(
      ip: '192.168.0.103',
      mac: '',
      isCandidate: true,
    );
    final controller = TransferController()
      ..addresses = ['192.168.0.104']
      ..selectedAddress = '192.168.0.104'
      ..devices = [candidate]
      ..discoveryStatus = '发现 1 个在线候选；请对照 FBI 屏幕上的 IP 选择';
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );

    expect(find.text('候选'), findsOneWidget);
    expect(find.text('192.168.0.103 · 请与 FBI 屏幕 IP 核对'), findsOneWidget);
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();

    expect(find.text('可能的 Nintendo 3DS'), findsOneWidget);
    expect(find.text('选择要安装的文件'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('exact FBI receiver is clearly labeled before selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const receiver = NearbyDevice(
      ip: '192.168.0.103',
      mac: '',
      isProtocolDiscovered: true,
    );
    final controller = TransferController()
      ..addresses = ['192.168.0.104']
      ..selectedAddress = '192.168.0.104'
      ..devices = [receiver]
      ..discoveryStatus = '发现 1 台正在等待接收的 3DS';
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );

    expect(find.text('FBI 就绪'), findsOneWidget);
    expect(find.text('192.168.0.103:5000 · 已开启网络接收'), findsOneWidget);
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();

    expect(find.text('FBI 接收模式'), findsOneWidget);
    expect(find.text('选择要安装的文件'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('theme menu can switch to dark mode', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = _readyController();
    await tester.pumpWidget(
      CiaBridgeApp(controller: controller, initializeController: false),
    );
    expect(find.text('3DShell.cia'), findsOneWidget);
    expect(find.byKey(const Key('primary-send-button')), findsOneWidget);
    expect(find.text('二维码'), findsOneWidget);

    await tester.tap(find.byKey(const Key('theme-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(find.text('Nintendo 3DS'), findsWidgets);
    expect(find.text('3DShell.cia'), findsOneWidget);
    expect(find.byKey(const Key('primary-send-button')), findsOneWidget);
    expect(find.text('二维码'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    controller.dispose();
  });

  testWidgets('file stage returns to discovery when device is cleared', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = _readyController();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: HomePage(controller: controller, initializeController: false),
      ),
    );
    expect(find.byKey(const Key('primary-send-button')), findsOneWidget);

    controller.setAddress(null);
    await tester.pumpAndSettle();

    expect(find.text('选择你的 Nintendo 3DS'), findsOneWidget);
    expect(find.byKey(const Key('primary-send-button')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    controller.dispose();
  });
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
    ..discoveryStatus = '发现 1 台 Nintendo 设备'
    ..status = '已选择 Nintendo 3DS · 192.168.0.103';
}
