import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device_state.dart';
import '../services/esp_service.dart';
import '../widgets/app_theme.dart';
import '../widgets/relay_card.dart';
import '../widgets/ldr_indicator.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final EspService _espService = EspService();
  DeviceState _state = const DeviceState();
  String _espIp = '';
  Timer? _refreshTimer;
  Timer? _heartbeatTimer;
  Timer? _debounceTimer;
  SharedPreferences? _prefs;
  bool _isConnected = false;
  bool _isSearching = true;

  // Labels modifiables pour les 4 relais
  final List<String> _relayLabels = [
    'Salon',
    'Cuisine',
    'Chambre',
    'Bureau',
  ];

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    final savedIp = _prefs?.getString('esp_ip');

    // Charger les noms personnalisés
    for (int i = 0; i < 4; i++) {
      final name = _prefs?.getString('relay_name_$i');
      if (name != null) {
        _relayLabels[i] = name;
      }
    }

    if (savedIp != null && savedIp.isNotEmpty) {
      setState(() {
        _espIp = savedIp;
        _espService.setIp(savedIp);
        _isSearching = true;
      });

      final connected = await _espService.heartbeat();
      if (connected) {
        setState(() {
          _isConnected = true;
          _isSearching = false;
        });
        _startAutoRefresh();
      } else {
        setState(() {
          _isConnected = false;
          _isSearching = false;
        });
      }
    }
    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      final connected = await _espService.heartbeat();
      if (mounted) {
        setState(() {
          _isConnected = connected;
        });
      }
    });
  }

  void _showPinDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceDark,
        title:
            const Text('BLight', style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Version avec 4 relais uniquement.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('OK', style: TextStyle(color: AppTheme.accentCool)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _startAutoRefresh() {
    _refreshData();
    _refreshTimer?.cancel(); // Sécurité
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refreshData();
    });
  }

  Future<void> _refreshData() async {
    if (_debounceTimer?.isActive == true) return;

    final newState = await _espService.fetchStatus();
    if (mounted) {
      setState(() {
        if (newState != null) {
          _state = newState;
        } else {
          _state = _state.copyWith(wifiConnected: false);
        }
      });
    }
  }

  Future<void> _toggleRelay(int index) async {
    // Optimistic UI Update - toggle immediately
    final previousState =
        _state.relayStates.length > index ? _state.relayStates[index] : false;
    final newStates = List<bool>.from(_state.relayStates);
    newStates[index] = !previousState;
    final newAutoModes = List<bool>.from(_state.relayAutoModes);
    newAutoModes[index] = false;

    setState(() {
      _state =
          _state.copyWith(relayStates: newStates, relayAutoModes: newAutoModes);
    });

    // Pause polling for 3 seconds (debounce)
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 3), () {});

    // Send to ESP
    final success = await _espService.toggleRelay(index);
    if (!success) {
      // Rollback on failure
      if (mounted) {
        setState(() {
          final rollbackStates = List<bool>.from(_state.relayStates);
          rollbackStates[index] = previousState;
          newAutoModes[index] = true;
          _state = _state.copyWith(
              relayStates: rollbackStates, relayAutoModes: newAutoModes);
        });
      }
    }
  }

  Future<void> _showRelayMenu(int index) async {
    final nameController = TextEditingController(text: _relayLabels[index]);

    await showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceDark,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 20,
            right: 20,
            top: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Réglages : ${_relayLabels[index]}',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            // Renommer
            TextField(
              controller: nameController,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Nom de l\'ampoule',
                labelStyle: TextStyle(color: AppTheme.accentCool),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: AppTheme.inactive)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: AppTheme.accentCool)),
              ),
            ),
            const SizedBox(height: 20),
            // Modes
            const Text('Mode de fonctionnement',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                ChoiceChip(
                  label: const Text('Manuel'),
                  selected: !_state.relayAutoModes[index],
                  onSelected: (val) {
                    _setRelayMode(index, false);
                    Navigator.pop(context);
                  },
                ),
                ChoiceChip(
                  label: const Text('Auto (LDR)'),
                  selected: _state.relayAutoModes[index],
                  onSelected: (val) {
                    _setRelayMode(index, true);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentWarm),
                onPressed: () async {
                  setState(() => _relayLabels[index] = nameController.text);
                  await _prefs?.setString(
                      'relay_name_$index', nameController.text);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Enregistrer les modifications',
                    style: TextStyle(color: Colors.black)),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _setRelayMode(int index, bool auto) async {
    final success = await _espService.setRelayMode(index, auto);
    if (success) _refreshData();
  }

  Future<void> _setAllModes(bool auto) async {
    for (int i = 0; i < 4; i++) {
      await _espService.setRelayMode(i, auto);
    }
    _refreshData();
  }

  @override
  Widget build(BuildContext context) {
    final isOffline = !_isConnected;
    final isAnyAuto = _state.relayAutoModes.contains(true);

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/logo.jpg',
                height: 32,
                width: 32,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'BLight',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_isSearching)
                    const Text(
                      'Recherche en cours...',
                      style: TextStyle(
                        color: AppTheme.accentCool,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Bouton cadenas pour accéder aux relais avancés
          IconButton(
            icon: Icon(
              Icons.info_outline,
              color: AppTheme.textSecondary,
            ),
            onPressed: _showPinDialog,
            tooltip: 'Accès avancé',
          ),
          // Bouton Paramètres
          IconButton(
            icon: const Icon(Icons.settings, color: AppTheme.textSecondary),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => SettingsScreen(
                  currentState: _state,
                  espService: _espService,
                  onRefresh: _refreshData,
                ),
              ),
            ),
          ),
          // Indicateur connexion (Heartbeat)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              _isConnected ? Icons.wifi : Icons.wifi_off,
              color: _isConnected ? Colors.blue : Colors.grey,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshData,
        color: AppTheme.accentWarm,
        backgroundColor: AppTheme.cardDark,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Indicateur LDR
              LDRIndicator(
                state: _state.ldrState,
                value: _state.ldrValue,
                modeAuto: isAnyAuto,
              ),
              const SizedBox(height: 24),

              // Contrôle Global Mode
              Wrap(
                spacing: 8.0,
                runSpacing: 8.0,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Contrôle Global',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.auto_awesome, size: 18),
                        label: const Text('Tout Auto'),
                        onPressed: isOffline ? null : () => _setAllModes(true),
                        style: TextButton.styleFrom(
                            foregroundColor: AppTheme.accentCool),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        icon: const Icon(Icons.back_hand, size: 18),
                        label: const Text('Tout Manuel'),
                        onPressed: isOffline ? null : () => _setAllModes(false),
                        style: TextButton.styleFrom(
                            foregroundColor: AppTheme.accentWarm),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Titre section
              const Text(
                'Lumières',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),

              // Grille 5 relais (2 colonnes)
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 1.1,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: 4,
                itemBuilder: (context, index) {
                  return RelayCard(
                    index: index,
                    isOn: _state.relayStates.length > index
                        ? _state.relayStates[index]
                        : false,
                    label: _relayLabels[index],
                    onToggle: () => _toggleRelay(index),
                    onLongPress: () => _showRelayMenu(index),
                    isOffline: isOffline,
                    isAutoMode: _state.relayAutoModes.length > index
                        ? _state.relayAutoModes[index]
                        : false,
                  );
                },
              ),

              // Info debug
              const SizedBox(height: 32),
              Center(
                child: Text(
                  'ESP IP: $_espIp${_state.ip.isNotEmpty ? " (detecté: ${_state.ip})" : ""}',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
