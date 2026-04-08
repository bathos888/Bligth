import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service Firebase Realtime Database via REST API
/// Pas besoin du SDK Firebase complet — HTTP suffit pour l'ESP et l'app
class FirebaseService {
  static const String _baseUrl =
      'https://blight-28253-default-rtdb.europe-west1.firebasedatabase.app';
  static const String _root = 'blight';

  // ============================================================
  // COMMANDES — App → Firebase → ESP
  // ============================================================

  /// Envoie une commande de toggle relais via Firebase
  /// L'ESP la récupère lors de son prochain poll
  Future<bool> sendRelayCommand(int index, bool state) async {
    try {
      final response = await http
          .put(
            Uri.parse('$_baseUrl/$_root/commands/relay_$index.json'),
            body: jsonEncode({
              'state': state,
              'done': false,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Envoie une commande de mode auto/manuel via Firebase
  Future<bool> sendModeCommand(int index, bool auto) async {
    try {
      final response = await http
          .put(
            Uri.parse('$_baseUrl/$_root/commands/mode_$index.json'),
            body: jsonEncode({
              'auto': auto,
              'done': false,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Envoie une commande de seuils via Firebase
  Future<bool> sendThresholdsCommand(int nuit, int jour) async {
    try {
      final response = await http
          .put(
            Uri.parse('$_baseUrl/$_root/commands/thresholds.json'),
            body: jsonEncode({
              'seuil_nuit': nuit,
              'seuil_jour': jour,
              'done': false,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // ============================================================
  // STATUS — ESP → Firebase → App
  // ============================================================

  /// Lit le dernier état publié par l'ESP dans Firebase
  Future<Map<String, dynamic>?> fetchStatus() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/$_root/status.json'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 && response.body != 'null') {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /// Écoute les changements de statut en temps réel (SSE Firebase)
  Stream<Map<String, dynamic>?> listenStatus() async* {
    while (true) {
      final status = await fetchStatus();
      yield status;
      await Future.delayed(const Duration(seconds: 3));
    }
  }

  // ============================================================
  // CONNEXION — Vérifier si Firebase est accessible
  // ============================================================
  Future<bool> isReachable() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/$_root/ping.json'))
          .timeout(const Duration(seconds: 4));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
