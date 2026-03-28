import 'package:flutter/material.dart';
import '../models/device_state.dart';
import '../services/esp_service.dart';
import '../widgets/app_theme.dart';
import '../widgets/relay_card.dart';

class AdvancedRelayScreen extends StatelessWidget {
  final DeviceState state;
  final List<String> relayLabels;
  final EspService espService;
  final Future<void> Function() onRefresh;
  final Future<void> Function(int) onToggleRelay;
  final Future<void> Function(int) onShowRelayMenu;

  const AdvancedRelayScreen({
    super.key,
    required this.state,
    required this.relayLabels,
    required this.espService,
    required this.onRefresh,
    required this.onToggleRelay,
    required this.onShowRelayMenu,
  });

  @override
  Widget build(BuildContext context) {
    final isOffline = !state.wifiConnected;

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Relais Avancés (6-8)',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.textSecondary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: onRefresh,
        color: AppTheme.accentWarm,
        backgroundColor: AppTheme.cardDark,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.accentCool.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: AppTheme.accentCool.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.lock_open, color: AppTheme.accentCool, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Zone sécurisée : ces relais permettent un contrôle avancé',
                        style:
                            TextStyle(color: AppTheme.accentCool, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Lumières Avancées',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 1.1,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: 3,
                itemBuilder: (context, index) {
                  final relayIndex = index + 5;
                  return RelayCard(
                    index: relayIndex,
                    isOn: state.relayStates.length > relayIndex
                        ? state.relayStates[relayIndex]
                        : false,
                    label: relayLabels[relayIndex],
                    onToggle: () => onToggleRelay(relayIndex),
                    onLongPress: () => onShowRelayMenu(relayIndex),
                    isOffline: isOffline,
                    isAutoMode: state.relayAutoModes.length > relayIndex
                        ? state.relayAutoModes[relayIndex]
                        : false,
                  );
                },
              ),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  'PIN: 1234',
                  style: TextStyle(
                    color: AppTheme.textSecondary.withOpacity(0.5),
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
