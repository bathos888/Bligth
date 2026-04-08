import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:http/http.dart' as http;
import '../models/device_state.dart';

class EspService {
  String _baseUrl = '';
  static const Duration _timeout = Duration(seconds: 3);

  String get baseUrl => _baseUrl;

  void setIp(String ip) {
    _baseUrl = ip.isNotEmpty ? 'http://$ip' : '';
  }

  // ============================================================
  // POINT D'ENTRÉE PRINCIPAL — 3 méthodes en cascade
  // ============================================================

  /// Découverte de l'ESP dans l'ordre :
  /// 1. IP sauvegardée → 2. mDNS (bonsoir) → 3. Scan réseau
  Future<String?> discoverEsp({String? savedIp}) async {
    // Étape 1 — IP déjà connue, encore valide ?
    if (savedIp != null && savedIp.isNotEmpty) {
      final alive = await _pingIp(savedIp);
      if (alive) {
        setIp(savedIp);
        return savedIp;
      }
    }

    // Étape 2 — mDNS via Bonsoir (Android + iOS)
    final mdnsIp = await _discoverViaBonsoir();
    if (mdnsIp != null) {
      setIp(mdnsIp);
      return mdnsIp;
    }

    // Étape 3 — Scan réseau parallèle (dernier recours)
    final scannedIp = await _scanNetwork();
    if (scannedIp != null) {
      setIp(scannedIp);
      return scannedIp;
    }

    return null;
  }

  // ============================================================
  // MÉTHODE 1 — mDNS avec Bonsoir
  // ============================================================
  Future<String?> _discoverViaBonsoir() async {
    final completer = Completer<String?>();
    BonsoirDiscovery? discovery;

    try {
      discovery = BonsoirDiscovery(type: '_http._tcp');
      await discovery.ready;

      discovery.eventStream?.listen((event) async {
        if (completer.isCompleted) return;

        // Service trouvé → on le résout pour obtenir l'IP
        if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
          event.service?.resolve(discovery!.serviceResolver);
        }

        // Service résolu → vérifier si c'est BLight
        if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
          final service = event.service as ResolvedBonsoirService?;
          if (service == null) return;

          final host = service.host ?? '';
          final name = service.name.toLowerCase();

          // Vérifier par le nom du service mDNS
          final isBlight = name.contains('blight') ||
              (service.attributes?['app']?.toString().contains('BLight') ==
                  true);

          if (host.isNotEmpty) {
            final ipToCheck = host.replaceAll('.local', '');

            if (isBlight) {
              // Nom reconnu → vérification HTTP directe
              final valid = await _pingIp(ipToCheck);
              if (valid && !completer.isCompleted) {
                completer.complete(ipToCheck);
              }
            } else {
              // Nom inconnu → quand même vérifier via HTTP
              // (au cas où le nom mDNS diffère)
              final valid = await _pingIp(ipToCheck);
              if (valid && !completer.isCompleted) {
                completer.complete(ipToCheck);
              }
            }
          }
        }
      });

      await discovery.start();

      // Timeout 5 secondes
      final result = await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );

      return result;
    } catch (e) {
      if (!completer.isCompleted) completer.complete(null);
      return null;
    } finally {
      try {
        await discovery?.stop();
      } catch (_) {}
    }
  }

  // ============================================================
  // MÉTHODE 2 — Scan réseau parallèle par batch de 50
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

      // Scan par batch de 50 IPs simultanées
      for (int batch = 0; batch < 6; batch++) {
        final start = batch * 50 + 1;
        final end = (start + 49).clamp(1, 254);

        final futures = List.generate(
          end - start + 1,
          (i) => _checkBLightAt('$subnet.${start + i}'),
        );

        final results = await Future.wait(futures);
        final found = results.firstWhere(
          (r) => r != null,
          orElse: () => null,
        );
        if (found != null) return found;
      }
    } catch (_) {}
    return null;
  }

  // ============================================================
  // HELPERS
  // ============================================================

  /// Retourne true si l'IP répond avec une API BLight valide
  Future<bool> _pingIp(String ip) async {
    return await _checkBLightAt(ip) != null;
  }

  /// Vérifie si une IP héberge BLight — retourne l'IP si oui, null sinon
  Future<String?> _checkBLightAt(String ip) async {
    try {
      final uri = Uri.parse(
        ip.startsWith('http')
            ? '$ip/api/status'
            : 'http://$ip/api/status',
      );

      final response = await http
          .get(uri)
          .timeout(const Duration(milliseconds: 600));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // ✅ Fix bug original : contains() au lieu de ==
        // Le firmware renvoie "BLight V1.0.7", pas "BLight"
        if (data['app'] != null &&
            data['app'].toString().contains('BLight')) {
          return ip;
        }
      }
    } catch (_) {}
    return null;
  }

  // ============================================================
  // API REST — inchangée
  // ============================================================

  Future<bool> heartbeat() async {
    if (_baseUrl.isEmpty) return false;
    return await _pingIp(_baseUrl);
  }

  /// Compatibilité avec SettingsScreen (bouton "Rechercher mon BLight")
  Future<String?> scanNetwork() => _scanNetwork();

  List<bool> _padToFour(List<bool> list) {
    while (list.length < 4) list.add(false);
    return list.take(4).toList();
  }

  Future<DeviceState?> fetchStatus() async {
    if (_baseUrl.isEmpty) return null;
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
    return null;
  }

  Future<bool> toggleRelay(int index) async {
    if (_baseUrl.isEmpty) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/relay/toggle'),
            body: jsonEncode({'index': index}),
          )
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setRelayMode(int index, bool auto) async {
    if (_baseUrl.isEmpty) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/mode'),
            body: jsonEncode({'index': index, 'auto': auto}),
          )
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> setThresholds(int nuit, int jour) async {
    if (_baseUrl.isEmpty) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/thresholds'),
            body: jsonEncode({'seuil_nuit': nuit, 'seuil_jour': jour}),
          )
          .timeout(_timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
