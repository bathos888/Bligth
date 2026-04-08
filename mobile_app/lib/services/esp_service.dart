import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:http/http.dart' as http;
import '../models/device_state.dart';
import 'firebase_service.dart';

/// Mode de connexion actif
enum ConnectionMode { local, firebase, none }

class EspService {
  String _baseUrl = '';
  static const Duration _timeout = Duration(seconds: 3);

  ConnectionMode _mode = ConnectionMode.none;
  ConnectionMode get mode => _mode;
  bool get isLocal => _mode == ConnectionMode.local;
  bool get isFirebase => _mode == ConnectionMode.firebase;

  final FirebaseService _firebase = FirebaseService();
  FirebaseService get firebase => _firebase;

  String get baseUrl => _baseUrl;

  void setIp(String ip) {
    _baseUrl = ip.isNotEmpty ? 'http://$ip' : '';
    if (ip.isNotEmpty) _mode = ConnectionMode.local;
  }

  // ============================================================
  // DÉCOUVERTE — 3 méthodes en cascade
  // ============================================================

  Future<String?> discoverEsp({String? savedIp}) async {
    // Étape 1 — IP sauvegardée
    if (savedIp != null && savedIp.isNotEmpty) {
      final alive = await _pingIp(savedIp);
      if (alive) {
        setIp(savedIp);
        _mode = ConnectionMode.local;
        return savedIp;
      }
    }

    // Étape 2 — mDNS
    final mdnsIp = await _discoverViaBonsoir();
    if (mdnsIp != null) {
      setIp(mdnsIp);
      _mode = ConnectionMode.local;
      return mdnsIp;
    }

    // Étape 3 — Scan réseau
    final scannedIp = await _scanNetwork();
    if (scannedIp != null) {
      setIp(scannedIp);
      _mode = ConnectionMode.local;
      return scannedIp;
    }

    // Étape 4 — Fallback Firebase
    final firebaseOk = await _firebase.isReachable();
    if (firebaseOk) {
      _mode = ConnectionMode.firebase;
      return 'firebase';
    }

    _mode = ConnectionMode.none;
    return null;
  }

  // ============================================================
  // mDNS via Bonsoir
  // ============================================================
  Future<String?> _discoverViaBonsoir() async {
    final completer = Completer<String?>();
    BonsoirDiscovery? discovery;

    try {
      discovery = BonsoirDiscovery(type: '_http._tcp');
      await discovery.ready;

      discovery.eventStream?.listen((event) async {
        if (completer.isCompleted) return;

        if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
          event.service?.resolve(discovery!.serviceResolver);
        }

        if (event.type ==
            BonsoirDiscoveryEventType.discoveryServiceResolved) {
          final service = event.service as ResolvedBonsoirService?;
          if (service == null) return;

          final host = service.host ?? '';
          final name = service.name.toLowerCase();

          if (host.isNotEmpty) {
            final ipToCheck = host.replaceAll('.local', '');
            final isBlight = name.contains('blight');

            if (isBlight || true) {
              final valid = await _pingIp(ipToCheck);
              if (valid && !completer.isCompleted) {
                completer.complete(ipToCheck);
              }
            }
          }
        }
      });

      await discovery.start();

      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );

      return result;
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
      return null;
    } finally {
      try {
        await discovery?.stop();
      } catch (_) {}
    }
  }

  // ============================================================
  // Scan réseau parallèle
  // ============================================================
  Future<String?> _scanNetwork() async {
    try {
      final interfaces = await NetworkInterface.list();
      String? localIp;

      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            localIp = addr.address;
            break;
          }
        }
        if (localIp != null) break;
      }

      if (localIp == null) return null;

      final parts = localIp.split('.');
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';

      for (int batch = 0; batch < 6; batch++) {
        final start = batch * 50 + 1;
        final end = (start + 49).clamp(1, 254);

        final futures = List.generate(
          end - start + 1,
          (i) => _checkBLightAt('$subnet.${start + i}'),
        );

        final results = await Future.wait(futures);
        final found = results.firstWhere((r) => r != null, orElse: () => null);
        if (found != null) return found;
      }
    } catch (_) {}
    return null;
  }

  // ============================================================
  // Helpers
  // ============================================================
  Future<bool> _pingIp(String ip) async {
    return await _checkBLightAt(ip) != null;
  }

  Future<String?> _checkBLightAt(String ip) async {
    try {
      final uri = Uri.parse(
        ip.startsWith('http')
            ? '$ip/api/status'
            : 'http://$ip/api/status',
      );
      final response =
          await http.get(uri).timeout(const Duration(milliseconds: 600));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['app'] != null &&
            data['app'].toString().contains('BLight')) {
          return ip;
        }
      }
    } catch (_) {}
    return null;
  }

  // ============================================================
  // Compatibilité SettingsScreen
  // ============================================================
  Future<String?> scanNetwork() => _scanNetwork();

  // ============================================================
  // API — hybride local / Firebase
  // ============================================================

  Future<bool> heartbeat() async {
    if (_mode == ConnectionMode.local && _baseUrl.isNotEmpty) {
      final alive = await _pingIp(_baseUrl);
      if (!alive) {
        // Rétrogradation vers Firebase si l'ESP local ne répond plus
        final fbOk = await _firebase.isReachable();
        _mode = fbOk ? ConnectionMode.firebase : ConnectionMode.none;
      }
      return alive;
    }
    if (_mode == ConnectionMode.firebase) {
      return await _firebase.isReachable();
    }
    return false;
  }

  List<bool> _padToFour(List<bool> list) {
    while (list.length < 4) list.add(false);
    return list.take(4).toList();
  }

  /// Récupère l'état — local si possible, Firebase sinon
  Future<DeviceState?> fetchStatus() async {
    if (_mode == ConnectionMode.local && _baseUrl.isNotEmpty) {
      try {
        final response = await http
            .get(Uri.parse('$_baseUrl/api/status'))
            .timeout(_timeout);
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          return DeviceState(
            ldrState: data['etat_ldr'] ?? 'JOUR',
            ldrValue: data['valeur_ldr'] ?? 0,
            seuilNuit: data['seuil_nuit'] ?? 300,
            seuilJour: data['seuil_jour'] ?? 700,
            wifiConnected: data['wifi_connected'] ?? false,
            ip: data['ip'] ?? '',
            relayStates:
                _padToFour(List<bool>.from(data['relays'] ?? [])),
            relayAutoModes:
                _padToFour(List<bool>.from(data['relay_modes'] ?? [])),
          );
        }
      } catch (_) {}
    }

    // Fallback Firebase
    if (_mode == ConnectionMode.firebase) {
      final data = await _firebase.fetchStatus();
      if (data != null) {
        final relays = data['relays'];
        final modes = data['relay_modes'];
        return DeviceState(
          ldrState: data['etat_ldr'] ?? 'JOUR',
          ldrValue: data['ldr_value'] ?? 0,
          seuilNuit: data['seuil_nuit'] ?? 300,
          seuilJour: data['seuil_jour'] ?? 700,
          wifiConnected: true,
          ip: data['ip'] ?? '',
          relayStates: _padToFour(
              relays != null ? List<bool>.from(relays) : []),
          relayAutoModes: _padToFour(
              modes != null ? List<bool>.from(modes) : []),
        );
      }
    }

    return null;
  }

  /// Toggle relais — local si possible, Firebase sinon
  Future<bool> toggleRelay(int index) async {
    if (_mode == ConnectionMode.local && _baseUrl.isNotEmpty) {
      try {
        final response = await http
            .post(
              Uri.parse('$_baseUrl/api/relay/toggle'),
              body: jsonEncode({'index': index}),
            )
            .timeout(_timeout);
        return response.statusCode == 200;
      } catch (_) {}
    }

    // Fallback Firebase — on envoie la commande, l'ESP l'exécutera
    if (_mode == ConnectionMode.firebase) {
      // On ne connaît pas l'état actuel exactement, on envoie toggle=true
      // L'ESP gère le toggle côté firmware
      return await _firebase.sendRelayCommand(index, true);
    }

    return false;
  }

  /// Toggle avec état connu — plus précis pour Firebase
  Future<bool> toggleRelayWithState(int index, bool currentState) async {
    if (_mode == ConnectionMode.local && _baseUrl.isNotEmpty) {
      try {
        final response = await http
            .post(
              Uri.parse('$_baseUrl/api/relay/toggle'),
              body: jsonEncode({'index': index}),
            )
            .timeout(_timeout);
        return response.statusCode == 200;
      } catch (_) {}
    }

    if (_mode == ConnectionMode.firebase) {
      return await _firebase.sendRelayCommand(index, !currentState);
    }

    return false;
  }

  Future<bool> setRelayMode(int index, bool auto) async {
    if (_mode == ConnectionMode.local && _baseUrl.isNotEmpty) {
      try {
        final response = await http
            .post(
              Uri.parse('$_baseUrl/api/mode'),
              body: jsonEncode({'index': index, 'auto': auto}),
            )
            .timeout(_timeout);
        return response.statusCode == 200;
      } catch (_) {}
    }

    if (_mode == ConnectionMode.firebase) {
      return await _firebase.sendModeCommand(index, auto);
    }

    return false;
  }

  Future<bool> setThresholds(int nuit, int jour) async {
    if (_mode == ConnectionMode.local && _baseUrl.isNotEmpty) {
      try {
        final response = await http
            .post(
              Uri.parse('$_baseUrl/api/thresholds'),
              body: jsonEncode({'seuil_nuit': nuit, 'seuil_jour': jour}),
            )
            .timeout(_timeout);
        return response.statusCode == 200;
      } catch (_) {}
    }

    if (_mode == ConnectionMode.firebase) {
      return await _firebase.sendThresholdsCommand(nuit, jour);
    }

    return false;
  }
}
