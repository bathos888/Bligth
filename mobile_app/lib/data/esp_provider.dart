import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'models.dart';

class EspProvider with ChangeNotifier {
  EspState _state = EspState.initial();
  String _espIp = "192.168.1.100"; // À configurer plus tard
  bool _isConnected = false;

  EspState get state => _state;
  bool get isConnected => _isConnected;

  // Récupérer l'état actuel de l'ESP
  Future<void> fetchStatus() async {
    try {
      final response = await http.get(Uri.parse('http://$_espIp/api/status')).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        _state = EspState.fromJson(jsonDecode(response.body));
        _isConnected = true;
      } else {
        _isConnected = false;
      }
    } catch (e) {
      _isConnected = false;
    }
    notifyListeners();
  }

  // Contrôler un relais
  Future<void> toggleRelay(int relayId, bool newState) async {
    try {
      final response = await http.post(
        Uri.parse('http://$_espIp/api/control'),
        body: {'relay_id': relayId.toString(), 'state': newState ? '1' : '0'},
      ).timeout(const Duration(seconds: 2));
      
      if (response.statusCode == 200) {
        await fetchStatus(); // Rafraîchir l'état
      }
    } catch (e) {
      debugPrint("Erreur contrôle relais : $e");
    }
  }

  // Changer le mode auto
  Future<void> setModeAuto(bool value) async {
    try {
      final response = await http.post(
        Uri.parse('http://$_espIp/api/control'),
        body: {'mode_auto': value ? '1' : '0'},
      ).timeout(const Duration(seconds: 2));
      
      if (response.statusCode == 200) {
        await fetchStatus();
      }
    } catch (e) {
      debugPrint("Erreur mode auto : $e");
    }
  }
}
