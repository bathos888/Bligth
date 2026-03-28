import 'package:flutter/material.dart';
import '../widgets/app_theme.dart';

class RelayCard extends StatelessWidget {
  final int index;
  final bool isOn;
  final String label;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final bool isOffline;
  final bool isAutoMode;

  const RelayCard({
    super.key,
    required this.index,
    required this.isOn,
    required this.label,
    required this.onToggle,
    required this.onLongPress,
    this.isOffline = false,
    this.isAutoMode = false,
  });

  @override
  Widget build(BuildContext context) {
    // Si offline, on grise tout
    final Color cardColor = isOffline ? AppTheme.cardDark.withOpacity(0.5) : AppTheme.cardDark;
    final Color iconColor = isOn ? AppTheme.accentWarm : AppTheme.textSecondary;
    
    return GestureDetector(
      onLongPress: isOffline ? null : onLongPress,
      onTap: isOffline ? null : onToggle, // Clic simple toggle aussi
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(24), // Coins plus ronds
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Ligne du haut : Icône et Switch
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(
                  isOn ? Icons.lightbulb : Icons.lightbulb_outline,
                  color: isOffline ? AppTheme.inactive : iconColor,
                  size: 28,
                ),
                
                // Badge AUTO discret
                if (isAutoMode && !isOffline)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.accentCool.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppTheme.accentCool.withOpacity(0.5), width: 0.5),
                    ),
                    child: const Text(
                      'AUTO',
                      style: TextStyle(
                        color: AppTheme.accentCool,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),

                // Switch mini
                SizedBox(
                  height: 24,
                  child: Switch(
                    value: isOn,
                    onChanged: isOffline ? null : (v) => onToggle(),
                    activeColor: AppTheme.accentWarm,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            
            const Spacer(),
            
            // Nom de la lampe
            Text(
              label,
              style: TextStyle(
                color: isOffline ? AppTheme.inactive : AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            
            const SizedBox(height: 4),
            
            // État / Mode (Manuel ou Auto)
            Text(
              isOffline 
                  ? 'Hors ligne' 
                  : (isAutoMode ? 'Mode Auto (LDR)' : 'Mode Manuel'),
              style: TextStyle(
                color: isOffline ? Colors.red : AppTheme.textSecondary,
                fontSize: 12,
                fontStyle: isAutoMode ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
