class AppConfig {
  // Mode Debug/Prod
  static const bool debugMode = true;
  
  // Timing communication ESP local
  static const Duration httpTimeout = Duration(seconds: 2);
  static const int espPort = 80;
  
  // Firebase paths (seront utilisés Étape 4)
  static const String firebaseRoot = 'lighting_controllers';
  
  // Seuils par défaut (synchrones avec le firmware)
  static const int defaultThresholdNight = 30;
  static const int defaultThresholdDay = 70;
}
