import 'package:equatable/equatable.dart';

class DeviceState extends Equatable {
  final String ldrState;
  final int ldrValue;
  final int seuilNuit;
  final int seuilJour;
  final bool wifiConnected;
  final String ip;
  final List<bool> relayStates;
  final List<bool> relayAutoModes; // NOUVEAU : Un mode par relais

  const DeviceState({
    this.ldrState = 'JOUR',
    this.ldrValue = 50,
    this.seuilNuit = 30,
    this.seuilJour = 70,
    this.wifiConnected = false,
    this.ip = '',
    this.relayStates = const [false, false, false, false],
    this.relayAutoModes = const [true, true, true, true],
  });

  DeviceState copyWith({
    String? ldrState,
    int? ldrValue,
    int? seuilNuit,
    int? seuilJour,
    bool? wifiConnected,
    String? ip,
    List<bool>? relayStates,
    List<bool>? relayAutoModes,
  }) {
    return DeviceState(
      ldrState: ldrState ?? this.ldrState,
      ldrValue: ldrValue ?? this.ldrValue,
      seuilNuit: seuilNuit ?? this.seuilNuit,
      seuilJour: seuilJour ?? this.seuilJour,
      wifiConnected: wifiConnected ?? this.wifiConnected,
      ip: ip ?? this.ip,
      relayStates: relayStates ?? this.relayStates,
      relayAutoModes: relayAutoModes ?? this.relayAutoModes,
    );
  }

  @override
  List<Object?> get props => [
        ldrState,
        ldrValue,
        seuilNuit,
        seuilJour,
        wifiConnected,
        ip,
        relayStates,
        relayAutoModes
      ];
}
