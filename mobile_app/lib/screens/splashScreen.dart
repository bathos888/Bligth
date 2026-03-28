import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/esp_service.dart';
import '../widgets/app_theme.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final EspService _espService = EspService();
  String _statusText = 'Recherche de BLight sur le réseau...';

  @override
  void initState() {
    super.initState();
    _statusText = 'Connexion à BLight...';
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = await prefs.getString('esp_ip');

    if (savedIp != null && savedIp.isNotEmpty) {
      setState(() => _statusText = 'Connexion à ${savedIp}...');
      _espService.setIp(savedIp);

      final connected = await _espService.heartbeat();
      if (connected) {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const HomeScreen()),
          );
        }
        return;
      }
    }

    setState(() => _statusText = 'Recherche de BLight...');

    final foundIp = await _espService.scanNetwork();

    if (foundIp != null) {
      await prefs.setString('esp_ip', foundIp);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    } else {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset(
                'assets/images/logo.jpg',
                height: 120,
                width: 120,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              'BLight',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 36,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 48),
            const CircularProgressIndicator(
              color: AppTheme.accentCool,
            ),
            const SizedBox(height: 24),
            Text(
              _statusText,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
