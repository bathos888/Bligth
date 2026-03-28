import 'package:flutter/material.dart';
import '../widgets/app_theme.dart';

class LDRIndicator extends StatelessWidget {
  final String state;      // JOUR, NUIT, DEBUT_NUIT, DEBUT_JOUR
  final int value;         // 0-100
  final bool modeAuto;

  const LDRIndicator({
    super.key,
    required this.state,
    required this.value,
    required this.modeAuto,
  });

  IconData get _icon {
    switch (state) {
      case 'JOUR':
      case 'DEBUT_NUIT':
        return Icons.wb_sunny;
      case 'NUIT':
      case 'DEBUT_JOUR':
        return Icons.nights_stay;
      default:
        return Icons.wb_cloudy;
    }
  }

  Color get _color {
    switch (state) {
      case 'JOUR':
        return Colors.orange;
      case 'NUIT':
        return Colors.indigo;
      case 'DEBUT_NUIT':
      case 'DEBUT_JOUR':
        return Colors.purple;  // Transition
      default:
        return AppTheme.textSecondary;
    }
  }

  String get _label {
    switch (state) {
      case 'JOUR':
        return 'Jour';
      case 'NUIT':
        return 'Nuit';
      case 'DEBUT_NUIT':
        return 'Crépuscule...';
      case 'DEBUT_JOUR':
        return 'Aube...';
      default:
        return 'Inconnu';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: AppTheme.cardDark,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // Icône animée
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _color.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(_icon, color: _color, size: 28),
          ),
          const SizedBox(width: 16),
          // Texte
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Luminosité: $value% • Mode: ${modeAuto ? 'Auto' : 'Manuel'}',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          // Barre de progression circulaire
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 50,
                height: 50,
                child: CircularProgressIndicator(
                  value: value / 100,
                  backgroundColor: AppTheme.inactive,
                  valueColor: AlwaysStoppedAnimation<Color>(_color),
                  strokeWidth: 4,
                ),
              ),
              Text(
                '$value',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
