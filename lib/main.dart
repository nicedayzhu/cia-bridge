import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'transfer_controller.dart';
import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CiaBridgeApp());
}

class CiaBridgeApp extends StatefulWidget {
  const CiaBridgeApp({
    super.key,
    this.controller,
    this.initializeController = true,
  });

  final TransferController? controller;
  final bool initializeController;

  @override
  State<CiaBridgeApp> createState() => _CiaBridgeAppState();
}

class _CiaBridgeAppState extends State<CiaBridgeApp> {
  ThemeMode _themeMode = ThemeMode.system;
  late final TransferController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TransferController();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CIA Bridge',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(brightness: Brightness.dark),
      themeMode: _themeMode,
      home: HomePage(
        controller: _controller,
        initializeController: widget.initializeController,
        themeMode: _themeMode,
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}
