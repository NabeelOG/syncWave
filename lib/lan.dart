import 'dart:convert';
import 'dart:io';

/// TCP port used by the Host's HTTP + WebSocket server.
const int kPort = 8080;

/// A SyncWave host discovered on the local network.
class FoundHost {
  final String name;
  final String ip;
  final int port;
  const FoundHost(this.name, this.ip, this.port);
}

/// Finds SyncWave hosts on the local network.
///
/// Works for both scenarios:
///  * both phones on the same Wi-Fi router (host is in the same /24)
///  * host phone runs a Personal Hotspot (host is the gateway, e.g. 192.168.43.1)
///
/// Only a plain HTTP GET is used, so no extra permissions or sockets are needed.
Future<List<FoundHost>> findHosts(List<String> myIps) async {
  final candidates = <String>{};

  // Same-router setups: every host address on my own subnet.
  for (final ip in myIps) {
    final parts = ip.split('.');
    if (parts.length != 4) continue;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    for (int i = 1; i <= 254; i++) {
      candidates.add('$prefix.$i');
    }
  }

  // Hotspot setups: the host phone is the gateway of these subnets.
  for (final subnet in const ['192.168.43', '192.168.137', '172.20.10']) {
    for (int i = 1; i <= 254; i++) {
      candidates.add('$subnet.$i');
    }
  }

  final found = <String, FoundHost>{};
  final list = candidates.toList();

  Future<void> probe(String ip) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 250);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip:8080/ping'))
          .timeout(const Duration(milliseconds: 350));
      final resp = await req.close().timeout(const Duration(milliseconds: 450));
      if (resp.statusCode != 200) return;
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['app'] != 'syncwave') return;
      found[ip] = FoundHost(
        (data['name'] as String?) ?? 'Party Host',
        ip,
        (data['port'] as num?)?.toInt() ?? 8080,
      );
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  const batch = 96;
  for (int i = 0; i < list.length; i += batch) {
    await Future.wait(list.skip(i).take(batch).map(probe));
  }

  return found.values.toList();
}

/// Cleans user typed host addresses: strips scheme, path and port.
String cleanHostInput(String input) {
  var ip = input.trim();
  ip = ip.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
  ip = ip.split('/').first;
  if (ip.contains(':')) ip = ip.split(':').first;
  return ip.trim();
}
