import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/app_theme.dart';
import '../services/esp_service.dart';
import '../models/device_state.dart';

class SettingsScreen extends StatefulWidget {
  final DeviceState currentState;
  final EspService espService;
  final Function onRefresh;

  const SettingsScreen({
    super.key,
    required this.currentState,
    required this.espService,
    required this.onRefresh,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late int _nuit;
  late int _jour;
  final _ipController = TextEditingController();
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _nuit = widget.currentState.seuilNuit;
    _jour = widget.currentState.seuilJour;
    _ipController.text = widget.espService.baseUrl.replaceFirst('http://', '');
  }

  Future<void> _resetNames() async {
    final prefs = await SharedPreferences.getInstance();
    for (int i = 0; i < 4; i++) {
      await prefs.remove('relay_name_$i');
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Noms réinitialisés. Redémarrez l\'app.')),
      );
    }
  }

  Future<void> _scanNetwork() async {
    setState(() => _isScanning = true);

    final foundIp = await widget.espService.scanNetwork();

    if (mounted) {
      setState(() => _isScanning = false);

      if (foundIp != null) {
        _ipController.text = foundIp;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('esp_ip', foundIp);
        widget.onRefresh();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('BLight trouvé : $foundIp'),
                backgroundColor: Colors.green),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Aucun BLight trouvé sur le réseau'),
                backgroundColor: Colors.orange),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        title: const Text('Paramètres'),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // En-tête avec Logo
          Center(
            child: Column(
              children: [
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    'assets/images/logo.jpg',
                    height: 80,
                    width: 80,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'BLight',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text(
                  'Domotique Résiliente',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),

          // Section Connexion
          _buildSectionTitle('Connexion ESP'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _ipController,
                    style: const TextStyle(color: AppTheme.textPrimary),
                    decoration: const InputDecoration(
                      labelText: 'Adresse de l\'ESP',
                      hintText: '192.168.1.50',
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isScanning ? null : _scanNetwork,
                      icon: _isScanning
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.search),
                      label: Text(_isScanning
                          ? 'Scan en cours...'
                          : 'Rechercher mon BLight'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final address = _ipController.text.isEmpty
                            ? ''
                            : _ipController.text;
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setString('esp_ip', address);
                        widget.espService.setIp(address);
                        widget.onRefresh();
                        if (mounted) Navigator.pop(context);
                      },
                      child: const Text('Utiliser cette IP'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),
          // Section Seuils
          _buildSectionTitle('Seuils de luminosité'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('Nuit: $_nuit (0-1023)',
                      style: const TextStyle(color: AppTheme.textSecondary)),
                  Slider(
                    value: _nuit.toDouble().clamp(0, 1023),
                    min: 0,
                    max: 1023,
                    divisions: 100,
                    onChanged: (v) => setState(() => _nuit = v.round()),
                  ),
                  Text('Jour: $_jour (0-1023)',
                      style: const TextStyle(color: AppTheme.textSecondary)),
                  Slider(
                    value: _jour.toDouble().clamp(0, 1023),
                    min: 0,
                    max: 1023,
                    divisions: 100,
                    onChanged: (v) => setState(() => _jour = v.round()),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      await widget.espService.setThresholds(_nuit, _jour);
                      widget.onRefresh();
                    },
                    child: const Text('Appliquer les seuils'),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),
          // Section Maintenance
          _buildSectionTitle('Maintenance'),
          ListTile(
            leading: const Icon(Icons.refresh, color: AppTheme.accentCool),
            title: const Text('Réinitialiser les noms'),
            subtitle:
                const Text('Remet les noms par défaut (Salon, Cuisine...)'),
            onTap: _resetNames,
          ),
          const Divider(color: AppTheme.inactive),
          ListTile(
            leading:
                const Icon(Icons.info_outline, color: AppTheme.textSecondary),
            title: const Text('Version Firmware'),
            subtitle: const Text('Bathos V 1.0.3'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
            color: AppTheme.accentCool,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2),
      ),
    );
  }
}
