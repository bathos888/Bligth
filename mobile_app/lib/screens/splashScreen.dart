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
  int _step = 0; // 0=init, 1=savedIp, 2=mdns, 3=scan, 4=done

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

      final alive = await _espService.discoverEsp(savedIp: savedIp);
      if (alive != null) {
        await prefs.setString('esp_ip', alive);
        setState(() => _statusText = 'BLight trouvé !');
        await Future.delayed(const Duration(milliseconds: 400));
        _navigateHome();
        return;
      }
    }

    // Étape 2 — mDNS
    setState(() {
      _step = 2;
      _statusText = 'Recherche via réseau local (mDNS)...';
    });

    final found = await _espService.discoverEsp();
    if (found != null) {
      await prefs.setString('esp_ip', found);
      setState(() => _statusText = 'BLight trouvé ! ($found)');
      await Future.delayed(const Duration(milliseconds: 400));
      _navigateHome();
      return;
    }

    // Étape 3 — Scan réseau (déjà tenté dans discoverEsp)
    // On arrive ici si tout a échoué
    setState(() {
      _step = 4;
      _statusText = 'BLight non trouvé. Mode hors ligne.';
    });
    await Future.delayed(const Duration(seconds: 1));
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

            // Titre
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
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 48),

            // Indicateur d'étape
            _buildStepIndicator(),
            const SizedBox(height: 24),

            // Spinner
            if (_step < 4)
              const CircularProgressIndicator(
                color: AppTheme.accentCool,
              )
            else
              const Icon(
                Icons.wifi_off,
                color: AppTheme.textSecondary,
                size: 32,
              ),

            const SizedBox(height: 24),

            // Texte de statut
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _statusText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    final steps = [
      {'label': 'IP mémorisée', 'step': 1},
      {'label': 'mDNS', 'step': 2},
      {'label': 'Scan réseau', 'step': 3},
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: steps.map((s) {
        final stepNum = s['step'] as int;
        final isDone = _step > stepNum;
        final isActive = _step == stepNum;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone
                      ? AppTheme.accentCool
                      : isActive
                          ? AppTheme.accentCool.withOpacity(0.3)
                          : AppTheme.cardDark,
                  border: Border.all(
                    color: isActive || isDone
                        ? AppTheme.accentCool
                        : AppTheme.inactive,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: isDone
                      ? const Icon(Icons.check, color: Colors.white, size: 16)
                      : isActive
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.accentCool,
                              ),
                            )
                          : Text(
                              '$stepNum',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s['label'] as String,
                style: TextStyle(
                  color: isActive || isDone
                      ? AppTheme.textPrimary
                      : AppTheme.textSecondary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
