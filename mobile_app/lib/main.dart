import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/splashScreen.dart';
import 'widgets/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Forcer orientation portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Status bar transparente
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  runApp(const SmartLightingApp());
}

class SmartLightingApp extends StatelessWidget {
  const SmartLightingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLight',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
