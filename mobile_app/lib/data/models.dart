class EspState {
  final int ldr;
  final bool modeAuto;
  final List<bool> relais;
  final int etatLdr; // 0: JOUR, 1: DEBUT_NUIT, 2: NUIT, 3: DEBUT_JOUR

  EspState({
    required this.ldr,
    required this.modeAuto,
    required this.relais,
    required this.etatLdr,
  });

  factory EspState.fromJson(Map<String, dynamic> json) {
    return EspState(
      ldr: json['ldr'] ?? 0,
      modeAuto: json['mode_auto'] ?? true,
      relais: List<bool>.from(json['relais'] ?? [false, false, false, false, false, false]),
      etatLdr: json['etat_ldr'] ?? 0,
    );
  }

  factory EspState.initial() {
    return EspState(
      ldr: 0,
      modeAuto: true,
      relais: List.filled(6, false),
      etatLdr: 0,
    );
  }
}
