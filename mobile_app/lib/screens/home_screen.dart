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

    for (int i = 0; i < 4; i++) {
      final name = _prefs?.getString('relay_name_$i');
      if (name != null) _relayLabels[i] = name;
    }

    setState(() => _isSearching = true);

    final found = await _espService.discoverEsp(savedIp: savedIp);

    if (found != null) {
      if (found != 'firebase') {
        await _prefs?.setString('esp_ip', found);
        setState(() => _espIp = found);
      }
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

    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 10), (_) async {
      final connected = await _espService.heartbeat();
      if (mounted) setState(() => _isConnected = connected);
    });
  }

  void _startAutoRefresh() {
    _refreshData();
    _refreshTimer?.cancel();
    final interval = _espService.isFirebase
        ? const Duration(seconds: 4)
        : const Duration(seconds: 2);
    _refreshTimer = Timer.periodic(interval, (_) => _refreshData());
  }

  Future<void> _refreshData() async {
    if (_debounceTimer?.isActive == true) return;
    final newState = await _espService.fetchStatus();
    if (mounted) {
      setState(() {
        if (newState != null) {
          _state = newState;
          _isConnected = true;
        } else {
          _state = _state.copyWith(wifiConnected: false);
        }
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _heartbeatTimer?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _toggleRelay(int index) async {
    final previousState = _state.relayStates.length > index
        ? _state.relayStates[index]
        : false;
    final newStates = List<bool>.from(_state.relayStates);
    newStates[index] = !previousState;
    final newAutoModes = List<bool>.from(_state.relayAutoModes);
    newAutoModes[index] = false;

    setState(() {
      _state = _state.copyWith(
          relayStates: newStates, relayAutoModes: newAutoModes);
    });

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 3), () {});

    final success = await _espService.toggleRelayWithState(index, previousState);
    if (!success && mounted) {
      setState(() {
        final rollback = List<bool>.from(_state.relayStates);
        rollback[index] = previousState;
        newAutoModes[index] = true;
        _state = _state.copyWith(
            relayStates: rollback, relayAutoModes: newAutoModes);
      });
    }
  }

  Future<void> _showRelayMenu(int index) async {
    final nameController =
        TextEditingController(text: _relayLabels[index]);

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
            const Text('Mode de fonctionnement',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: [
                ChoiceChip(
                  label: const Text('Manuel'),
                  selected: !_state.relayAutoModes[index],
                  onSelected: (_) {
                    _setRelayMode(index, false);
                    Navigator.pop(context);
                  },
                ),
                ChoiceChip(
                  label: const Text('Auto (LDR)'),
                  selected: _state.relayAutoModes[index],
                  onSelected: (_) {
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
                  setState(
                      () => _relayLabels[index] = nameController.text);
                  await _prefs?.setString(
                      'relay_name_$index', nameController.text);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Enregistrer',
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
    await _espService.setRelayMode(index, auto);
    _refreshData();
  }

  Future<void> _setAllModes(bool auto) async {
    for (int i = 0; i < 4; i++) {
      await _espService.setRelayMode(i, auto);
    }
    _refreshData();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final isOffline = !_isConnected;
    final isAnyAuto = _state.relayAutoModes.contains(true);
    final isFirebaseMode = _espService.isFirebase;

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/images/logo.jpg',
                  height: 32, width: 32, fit: BoxFit.cover),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('BLight',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.bold)),
                  if (_isSearching)
                    const Text('Recherche en cours...',
                        style: TextStyle(
                            color: AppTheme.accentCool, fontSize: 10)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Badge mode connexion
          if (!_isSearching)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _buildConnectionBadge(isFirebaseMode, isOffline),
            ),
          // Paramètres
          IconButton(
            icon: const Icon(Icons.settings, color: AppTheme.textSecondary),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  currentState: _state,
                  espService: _espService,
                  onRefresh: _refreshData,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Banner Firebase mode
          if (isFirebaseMode && _isConnected)
            _buildFirebaseBanner(),

          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshData,
              color: AppTheme.accentWarm,
              backgroundColor: AppTheme.cardDark,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LDRIndicator(
                      state: _state.ldrState,
                      value: _state.ldrValue,
                      modeAuto: isAnyAuto,
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text('Contrôle Global',
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w600)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton.icon(
                              icon:
                                  const Icon(Icons.auto_awesome, size: 18),
                              label: const Text('Tout Auto'),
                              onPressed: isOffline
                                  ? null
                                  : () => _setAllModes(true),
                              style: TextButton.styleFrom(
                                  foregroundColor: AppTheme.accentCool),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              icon: const Icon(Icons.back_hand, size: 18),
                              label: const Text('Tout Manuel'),
                              onPressed: isOffline
                                  ? null
                                  : () => _setAllModes(false),
                              style: TextButton.styleFrom(
                                  foregroundColor: AppTheme.accentWarm),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Grille relais (bas fixe)
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Lumières',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
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
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    isFirebaseMode
                        ? '🌐 Contrôle via Internet (Firebase)'
                        : 'ESP IP: $_espIp',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionBadge(bool isFirebase, bool isOffline) {
    if (isOffline) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withOpacity(0.5)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, color: Colors.red, size: 14),
            SizedBox(width: 4),
            Text('Hors ligne',
                style: TextStyle(color: Colors.red, fontSize: 11)),
          ],
        ),
      );
    }

    if (isFirebase) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withOpacity(0.5)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud, color: Colors.orange, size: 14),
            SizedBox(width: 4),
            Text('Internet',
                style: TextStyle(color: Colors.orange, fontSize: 11)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green.withOpacity(0.5)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi, color: Colors.green, size: 14),
          SizedBox(width: 4),
          Text('Local',
              style: TextStyle(color: Colors.green, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildFirebaseBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.orange.withOpacity(0.15),
      child: const Row(
        children: [
          Icon(Icons.cloud_queue, color: Colors.orange, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Mode Internet — commandes envoyées via Firebase, l\'ESP les applique automatiquement.',
              style: TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
