import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/device_state.dart';

class EspService {
  String _baseUrl = '';
  final Duration timeout = const Duration(seconds: 2);

  void setIp(String ip) {
    if (ip.isNotEmpty) {
      _baseUrl = 'http://$ip';
    } else {
      _baseUrl = '';
    }
  }

  List<bool> _padToFour(List<bool> list) {
    while (list.length < 4) {
      list.add(false);
    }
    return list.take(4).toList();
  }

  String get baseUrl => _baseUrl;

  Future<bool> heartbeat() async {
    if (_baseUrl.isEmpty) return false;
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/api/status'))
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<String?> scanNetwork() async {
    try {
      final interfaces = await NetworkInterface.list();
      String? localIp;

      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
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

      for (int i = 1; i <= 254; i++) {
        final ip = '$subnet.$i';
        try {
          final response = await http
              .get(Uri.parse('http://$ip/api/status'))
              .timeout(const Duration(milliseconds: 150));

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['app'] == 'BLight') {
              setIp(ip);
              return ip;
            }
          }
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  Future<DeviceState?> fetchStatus() async {
    if (_baseUrl.isEmpty) return null;
    try {
      final response =
          await http.get(Uri.parse('$_baseUrl/api/status')).timeout(timeout);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return DeviceState(
          ldrState: data['etat_ldr'] ?? 'JOUR',
          ldrValue: data['valeur_ldr'] ?? 0,
          seuilNuit: data['seuil_nuit'] ?? 30,
          seuilJour: data['seuil_jour'] ?? 70,
          wifiConnected: data['wifi_connected'] ?? false,
          ip: data['ip'] ?? '',
          relayStates: _padToFour(List<bool>.from(data['relays'] ?? [])),
          relayAutoModes:
              _padToFour(List<bool>.from(data['relay_modes'] ?? [])),
        );
      }
    } catch (e) {
      return null;
    }
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
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // NOUVEAU : setMode accepte maintenant l'index du relais
  Future<bool> setRelayMode(int index, bool auto) async {
    if (_baseUrl.isEmpty) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/api/mode'),
            body: jsonEncode({'index': index, 'auto': auto}),
          )
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (e) {
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
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}
