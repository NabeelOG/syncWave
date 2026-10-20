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

/// Gateways of the hotspot flavours Android/iOS/Windows use. A phone that runs
/// a Personal Hotspot *is* the gateway, so its party is always reachable at one
/// of these addresses.
const List<String> kHotspotGateways = [
  '192.168.43.1', // Android
  '192.168.137.1', // Windows mobile hotspot
  '172.20.10.1', // iPhone
  '192.168.49.1', // some Android builds
  '192.168.147.1', // some Samsung builds
  '192.168.155.1', // some Samsung builds
];

/// Finds SyncWave hosts on the local network.
///
/// Works for both scenarios:
///  * both phones on the same Wi-Fi router (host is in the same /24)
///  * host phone runs a Personal Hotspot (host is the gateway)
///
/// Only a plain HTTP GET is used, so no extra permissions or sockets are
/// needed.
///
/// The sweep runs [rounds] times: the first attempt on an address usually
/// fails because the ARP entry is not cached yet, so a second pass is what
/// actually finds the host.
Future<List<FoundHost>> findHosts(
  List<String> myIps, {
  int rounds = 2,
}) async {
  final candidates = <String>{};

  // Hotspot gateways first: they are the most likely host address and should
  // be probed in the very first batch.
  candidates.addAll(kHotspotGateways);

  // Same-router setups: every host address on my own subnet.
  for (final ip in myIps) {
    final parts = ip.split('.');
    if (parts.length != 4) continue;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    for (int i = 1; i <= 254; i++) {
      candidates.add('$prefix.$i');
    }
  }

  final found = <String, FoundHost>{};
  final list = candidates.toList();

  Future<void> probe(String ip) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 300);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip:$kPort/ping'))
          .timeout(const Duration(milliseconds: 400));
      final resp = await req.close().timeout(const Duration(milliseconds: 500));
      if (resp.statusCode != 200) return;
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['app'] != 'syncwave') return;
      found[ip] = FoundHost(
        (data['name'] as String?) ?? 'Party Host',
        ip,
        (data['port'] as num?)?.toInt() ?? kPort,
      );
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  const batch = 64;
  for (int round = 0; round < rounds; round++) {
    for (int i = 0; i < list.length; i += batch) {
      await Future.wait(list.skip(i).take(batch).map(probe));
    }
    // Give the network a moment (and the ARP cache time to fill) before the
    // next pass - the second pass is the one that usually finds the host.
    if (round < rounds - 1) {
      await Future.delayed(const Duration(milliseconds: 400));
    }
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
