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
  String _statusText = 'Démarrage...';
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('esp_ip');

    // Étape 1 — IP sauvegardée
    if (savedIp != null && savedIp.isNotEmpty) {
      setState(() {
        _step = 1;
        _statusText = 'Connexion à BLight ($savedIp)...';
      });
    } else {
      setState(() {
        _step = 2;
        _statusText = 'Recherche via réseau local...';
      });
    }

    final found = await _espService.discoverEsp(savedIp: savedIp);

    if (found == null) {
      // Aucune connexion
      setState(() {
        _step = 5;
        _statusText = 'Aucune connexion disponible. Mode hors ligne.';
      });
      await Future.delayed(const Duration(seconds: 1));
      _navigateHome();
      return;
    }

    if (found == 'firebase') {
      // Connexion Firebase
      setState(() {
        _step = 4;
        _statusText = 'Connecté via Internet (Firebase) ☁️';
      });
    } else {
      // Connexion locale
      await prefs.setString('esp_ip', found);
      setState(() {
        _step = 3;
        _statusText = 'BLight trouvé ! ($found) ✅';
      });
    }

    await Future.delayed(const Duration(milliseconds: 500));
    _navigateHome();
  }

  void _navigateHome() {
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
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
            // Logo
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
            const SizedBox(height: 8),
            const Text(
              'Domotique Résiliente',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 48),

            // Étapes
            _buildSteps(),
            const SizedBox(height: 32),

            // Spinner ou icône finale
            if (_step < 3 || _step == 2)
              const CircularProgressIndicator(color: AppTheme.accentCool)
            else if (_step == 3)
              const Icon(Icons.wifi, color: Colors.green, size: 36)
            else if (_step == 4)
              const Icon(Icons.cloud_done, color: Colors.orange, size: 36)
            else
              const Icon(Icons.wifi_off, color: Colors.grey, size: 36),

            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _statusText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSteps() {
    final steps = [
      {'label': 'IP mémorisée', 'icon': Icons.bookmark},
      {'label': 'mDNS/Scan', 'icon': Icons.wifi_find},
      {'label': 'Firebase', 'icon': Icons.cloud},
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(steps.length, (i) {
        final stepNum = i + 1;
        final isDone = _step > stepNum && _step < 5;
        final isActive = _step == stepNum;
        final isFailed = _step == 5;

        return Row(
          children: [
            Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone
                        ? AppTheme.accentCool
                        : isActive
                            ? AppTheme.accentCool.withOpacity(0.3)
                            : isFailed
                                ? Colors.red.withOpacity(0.2)
                                : AppTheme.cardDark,
                    border: Border.all(
                      color: isDone || isActive
                          ? AppTheme.accentCool
                          : isFailed
                              ? Colors.red
                              : AppTheme.inactive,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: isDone
                        ? const Icon(Icons.check,
                            color: Colors.white, size: 18)
                        : isActive
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.accentCool,
                                ),
                              )
                            : Icon(
                                steps[i]['icon'] as IconData,
                                color: isFailed
                                    ? Colors.red
                                    : AppTheme.textSecondary,
                                size: 18,
                              ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  steps[i]['label'] as String,
                  style: TextStyle(
                    color: isDone || isActive
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            if (i < steps.length - 1)
              Container(
                width: 30,
                height: 2,
                margin: const EdgeInsets.only(bottom: 20),
                color: isDone ? AppTheme.accentCool : AppTheme.inactive,
              ),
          ],
        );
      }),
    );
  }
}
