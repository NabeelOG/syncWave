import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'clock_sync.dart';
import 'ram_audio_source.dart';

class DiscoveredHost {
  final String hostName;
  final String ip;
  final int httpPort;
  final int udpPort;
  final DateTime seenAt;

  const DiscoveredHost({
    required this.hostName,
    required this.ip,
    required this.httpPort,
    required this.udpPort,
    required this.seenAt,
  });
}

class ClientScreen extends StatefulWidget {
  final String deviceName;
  const ClientScreen({super.key, required this.deviceName});

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  final AudioPlayer _player = AudioPlayer();
  final ClockSyncFilter _clockFilter = ClockSyncFilter();
  final TextEditingController _manualController = TextEditingController();
  MobileScannerController? _scannerController;

  bool _cameraGranted = false;
  bool _checkingCamera = true;
  bool _showScanner = false;
  String? _scannerError;

  WebSocket? _ws;
  RawDatagramSocket? _udpSocket;
  RawDatagramSocket? _discoverySocket;
  String? _hostIp;
  int _httpPort = 8080;
  int _udpPort = 8081;

  bool _connected = false;
  bool _connecting = false;
  bool _scanning = false;
  String? _joinError;
  List<String> _myIps = <String>[];

  final Map<String, DiscoveredHost> _hosts = {};

  String _songTitle = 'Waiting for host to pick a song...';
  bool _readyInRam = false;
  bool _downloading = false;
  int _downloadPercent = 0;

  bool _roomPlaying = false;
  double _startHostTimeMs = 0.0;
  double _startTrackPosSec = 0.0;
  double _currentRate = 1.0;

  Timer? _syncTimer;
  Timer? _heartbeatTimer;
  Timer? _probeTimer;
  Timer? _sweepTimer;
  Timer? _scheduledStartTimer;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _bootstrap();
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _keepInSync(),
    );
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _sendBackgroundSyncAndStatus(),
    );
  }

  Future<void> _bootstrap() async {
    final ips = await detectLanIps();
    if (mounted) setState(() => _myIps = ips);

    await _startDiscovery();
    _sweepSubnet();

    final status = await Permission.camera.request();
    if (!mounted) return;
    if (status.isGranted) {
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        facing: CameraFacing.back,
      );
      setState(() {
        _cameraGranted = true;
        _checkingCamera = false;
        _showScanner = true;
      });
    } else {
      setState(() {
        _cameraGranted = false;
        _checkingCamera = false;
        _showScanner = false;
      });
    }
  }

  Future<void> _startDiscovery() async {
    try {
      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8082,
        reuseAddress: true,
      );
      _discoverySocket!.broadcastEnabled = true;

      _discoverySocket!.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final dg = _discoverySocket!.receive();
        if (dg == null) return;
        final String msg = utf8.decode(dg.data, allowMalformed: true);
        if (!msg.startsWith('SYNCWAVE_HOST,')) return;

        final parts = msg.split(',');
        if (parts.length < 5) return;

        final reportedIp = parts[2].trim();
        final senderIp = dg.address.address;
        final ip = (senderIp.isNotEmpty && senderIp != '0.0.0.0')
            ? senderIp
            : reportedIp;
        if (ip.isEmpty || ip == '0.0.0.0' || ip.startsWith('127.')) return;

        final host = DiscoveredHost(
          hostName: parts[1].trim().isEmpty ? 'Party Host' : parts[1].trim(),
          ip: ip,
          httpPort: int.tryParse(parts[3]) ?? 8080,
          udpPort: int.tryParse(parts[4]) ?? 8081,
          seenAt: DateTime.now(),
        );

        if (mounted) {
          setState(() => _hosts[ip] = host);
        }
      });

      _probeTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        if (_connected || _discoverySocket == null) return;
        try {
          _discoverySocket!.send(
            utf8.encode('DISCOVER_SYNCWAVE'),
            InternetAddress('255.255.255.255'),
            8081,
          );
          for (final ip in _myIps) {
            final o = ip.split('.');
            if (o.length == 4) {
              _discoverySocket!.send(
                utf8.encode('DISCOVER_SYNCWAVE'),
                InternetAddress('${o[0]}.${o[1]}.${o[2]}.255'),
                8081,
              );
            }
          }
        } catch (_) {}
      });

      // Keep list fresh: drop hosts not seen for 12s
      _sweepTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        if (!mounted) return;
        final cutoff = DateTime.now().subtract(const Duration(seconds: 12));
        setState(() {
          _hosts.removeWhere((_, h) => h.seenAt.isBefore(cutoff));
        });
      });
    } catch (_) {}
  }

  Future<void> _sweepSubnet() async {
    if (_scanning || _connected) return;
    setState(() => _scanning = true);

    final Set<String> candidates = <String>{
      '192.168.43.1', // Android hotspot
      '192.168.137.1', // Windows hotspot
      '172.20.10.1', // iPhone hotspot
    };
    for (final ip in _myIps) {
      final o = ip.split('.');
      if (o.length == 4) {
        for (int i = 1; i <= 254; i++) {
          candidates.add('${o[0]}.${o[1]}.${o[2]}.$i');
        }
      }
    }

    final List<String> list = candidates.toList();
    const int batch = 48;
    for (int i = 0; i < list.length; i += batch) {
      if (!mounted || _connected) break;
      await Future.wait(list.skip(i).take(batch).map(_probeHost));
    }

    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _probeHost(String ip) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 350);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip:8080/ping'))
          .timeout(const Duration(milliseconds: 420));
      final resp = await req.close().timeout(const Duration(milliseconds: 500));
      if (resp.statusCode != 200) return;
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['app'] != 'syncwave') return;
      if (!mounted) return;
      setState(() {
        _hosts[ip] = DiscoveredHost(
          hostName: (data['hostName'] as String?) ?? 'Party Host',
          ip: ip,
          httpPort: (data['httpPort'] as num?)?.toInt() ?? 8080,
          udpPort: (data['udpPort'] as num?)?.toInt() ?? 8081,
          seenAt: DateTime.now(),
        );
      });
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  void _onQrDetected(BarcodeCapture capture) {
    if (_connected || _connecting) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      if (raw.startsWith('syncwave://')) {
        final stripped = raw.replaceFirst('syncwave://', '').trim();
        final parts = stripped.split(':');
        if (parts.isNotEmpty) {
          _connectTo(
            parts[0],
            httpPort: parts.length > 1 ? (int.tryParse(parts[1]) ?? 8080) : 8080,
            udpPort: parts.length > 2 ? (int.tryParse(parts[2]) ?? 8081) : 8081,
          );
          return;
        }
      }
    }
  }

  Future<void> _connectTo(
    String rawInput, {
    int httpPort = 8080,
    int udpPort = 8081,
  }) async {
    String ip = rawInput.trim();
    ip = ip.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    ip = ip.split('/').first;

    if (ip.contains(':')) {
      final p = ip.split(':');
      ip = p[0].trim();
      httpPort = int.tryParse(p[1].trim()) ?? httpPort;
    }
    if (ip.isEmpty) {
      setState(() => _joinError = 'Enter the Host IP shown on the Host phone.');
      return;
    }

    setState(() {
      _connecting = true;
      _joinError = null;
      _hostIp = ip;
      _httpPort = httpPort;
      _udpPort = udpPort;
    });

    // 1. Verify the host is reachable before opening the WebSocket.
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      final req = await client
          .getUrl(Uri.parse('http://$ip:$httpPort/ping'))
          .timeout(const Duration(seconds: 4));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['app'] != 'syncwave') {
        throw const FormatException('Not a SyncWave host');
      }
      httpPort = (data['httpPort'] as num?)?.toInt() ?? httpPort;
      udpPort = (data['udpPort'] as num?)?.toInt() ?? udpPort;
    } catch (_) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _joinError =
              'Cannot reach $ip:$httpPort. Both phones must be on the SAME Wi-Fi/Hotspot.';
        });
      }
      return;
    }

    try {
      _clockFilter.reset();

      _udpSocket?.close();
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpSocket!.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final dg = _udpSocket!.receive();
        if (dg == null) return;
        final t4 = MonotonicClock.nowMs();
        final parts = utf8.decode(dg.data, allowMalformed: true).split(',');
        if (parts.length == 4 && parts[0] == 'PONG') {
          final t1 = double.tryParse(parts[1]);
          final t2 = double.tryParse(parts[2]);
          final t3 = double.tryParse(parts[3]);
          if (t1 != null && t2 != null && t3 != null) {
            _clockFilter.addSample(t1, t2, t3, t4);
          }
        }
      });

      final ws = await WebSocket.connect('ws://$ip:$httpPort/ws')
          .timeout(const Duration(seconds: 6));
      _ws = ws;

      try {
        await _scannerController?.stop();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _connected = true;
          _connecting = false;
          _joinError = null;
        });
      }

      ws.listen(
        (dynamic data) => _handleHostMessage(data as String),
        onDone: _handleDisconnected,
        onError: (_) => _handleDisconnected(),
      );

      _runInitialSyncBurst(ip, udpPort);
      _sendStatusUpdate();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connected = false;
          _joinError = 'Host found but control channel failed: $e';
        });
      }
    }
  }

  void _handleDisconnected() {
    _scheduledStartTimer?.cancel();
    _player.stop();
    try {
      _scannerController?.start();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _connected = false;
        _connecting = false;
        _roomPlaying = false;
        _readyInRam = false;
      });
    }
  }

  Future<void> _runInitialSyncBurst(String hostIp, int udpPort) async {
    final dest = InternetAddress.tryParse(hostIp);
    for (int i = 0; i < 25; i++) {
      if (!_connected) break;
      final t1 = MonotonicClock.nowMs();
      if (dest != null) {
        try {
          _udpSocket?.send(
            utf8.encode('PING,${t1.toStringAsFixed(3)}'),
            dest,
            udpPort,
          );
        } catch (_) {}
      }
      _ws?.add(jsonEncode({'type': 'SYNC_PING', 't1': t1}));
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  void _sendBackgroundSyncAndStatus() {
    if (!_connected || _hostIp == null) return;
    final t1 = MonotonicClock.nowMs();
    final dest = InternetAddress.tryParse(_hostIp!);
    if (dest != null) {
      try {
        _udpSocket?.send(
          utf8.encode('PING,${t1.toStringAsFixed(3)}'),
          dest,
          _udpPort,
        );
      } catch (_) {}
    }
    _ws?.add(jsonEncode({'type': 'SYNC_PING', 't1': t1}));
    _sendStatusUpdate();
  }

  void _sendStatusUpdate() {
    if (_ws == null || !_connected) return;
    try {
      _ws!.add(jsonEncode({
        'type': 'PEER_STATUS',
        'name': widget.deviceName,
        'readyInRam': _readyInRam,
        'downloadPercent': _downloadPercent,
      }));
    } catch (_) {}
  }

  Future<void> _handleHostMessage(String raw) async {
    final t4 = MonotonicClock.nowMs();
    final msg = jsonDecode(raw) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'SYNC_PONG':
        _clockFilter.addSample(
          (msg['t1'] as num).toDouble(),
          (msg['t2'] as num).toDouble(),
          (msg['t3'] as num).toDouble(),
          t4,
        );
        break;

      case 'LOAD_TRACK':
        final trackId = (msg['trackId'] as String?) ?? '';
        final url = 'http://$_hostIp:$_httpPort/track.mp3?id=$trackId';
        final title = (msg['title'] as String?) ?? 'Shared Song';
        final size = (msg['size'] as num?)?.toInt() ?? 0;
        await _downloadSongIntoRam(url, title, size);
        break;

      case 'PLAY_AT':
        await _executeScheduledPlay(
          (msg['startServerTimeMs'] as num).toDouble(),
          (msg['startTrackPosSec'] as num).toDouble(),
        );
        break;

      case 'PAUSE':
        _scheduledStartTimer?.cancel();
        final posSec = (msg['posSec'] as num).toDouble();
        if (mounted) setState(() => _roomPlaying = false);
        await _player.pause();
        await _player.seek(Duration(milliseconds: (posSec * 1000).round()));
        break;
    }
  }

  Future<void> _downloadSongIntoRam(
    String url,
    String title,
    int expectedSize,
  ) async {
    _scheduledStartTimer?.cancel();
    await _player.stop();

    if (mounted) {
      setState(() {
        _songTitle = title;
        _readyInRam = false;
        _downloading = true;
        _downloadPercent = 0;
        _roomPlaying = false;
      });
    }
    _sendStatusUpdate();

    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();

      final total = resp.contentLength > 0 ? resp.contentLength : expectedSize;
      final builder = BytesBuilder(copy: false);
      int received = 0;

      await for (final chunk in resp) {
        builder.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final pct = ((received / total) * 100).clamp(0, 99).round();
          if (pct != _downloadPercent && mounted) {
            setState(() => _downloadPercent = pct);
            _sendStatusUpdate();
          }
        }
      }

      final bytes = builder.takeBytes();
      await _player.setAudioSource(RamAudioSource(bytes));

      if (mounted) {
        setState(() {
          _downloading = false;
          _readyInRam = true;
          _downloadPercent = 100;
        });
      }
      _sendStatusUpdate();
    } catch (_) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _readyInRam = false;
        });
      }
    }
  }

  Future<void> _executeScheduledPlay(
    double startServerTimeMs,
    double startPosSec,
  ) async {
    if (!_readyInRam) return;
    _scheduledStartTimer?.cancel();

    if (mounted) {
      setState(() {
        _roomPlaying = true;
        _startHostTimeMs = startServerTimeMs;
        _startTrackPosSec = startPosSec;
      });
    }

    await _player.pause();
    await _player.setSpeed(1.0);
    _currentRate = 1.0;

    final hostNowMs = _clockFilter.estimatedHostNowMs();
    final waitMs = startServerTimeMs - hostNowMs;

    if (waitMs > 0) {
      await _player.seek(Duration(milliseconds: (startPosSec * 1000).round()));
      _scheduledStartTimer = Timer(
        Duration(microseconds: (waitMs * 1000).round()),
        () => _player.play(),
      );
    } else {
      final catchUpSec = startPosSec + (-waitMs / 1000.0);
      await _player.seek(Duration(milliseconds: (catchUpSec * 1000).round()));
      _player.play();
    }
  }

  void _keepInSync() {
    if (!_roomPlaying || !_player.playing || !_readyInRam) return;

    final hostNowMs = _clockFilter.estimatedHostNowMs();
    final elapsedSec = (hostNowMs - _startHostTimeMs) / 1000.0;
    if (elapsedSec < 0.25) return;

    final expectedMs = (_startTrackPosSec + elapsedSec) * 1000.0;
    final actualMs = _player.position.inMilliseconds.toDouble();
    final d = PllController.evaluate(
      expectedPosMs: expectedMs,
      actualPosMs: actualMs,
    );

    if (d.zone == PllZone.hardSeek) {
      _player.seek(Duration(milliseconds: expectedMs.round()));
      if (_currentRate != 1.0) {
        _currentRate = 1.0;
        _player.setSpeed(1.0);
      }
    } else if ((d.targetSpeed - _currentRate).abs() > 0.0005) {
      _currentRate = d.targetSpeed;
      _player.setSpeed(d.targetSpeed);
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _heartbeatTimer?.cancel();
    _probeTimer?.cancel();
    _sweepTimer?.cancel();
    _scheduledStartTimer?.cancel();
    _scannerController?.dispose();
    _ws?.close();
    _udpSocket?.close();
    _discoverySocket?.close();
    _manualController.dispose();
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_connected ? 'Party Speaker' : 'Join Party'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: _connected ? _buildConnectedPlayerView() : _buildJoinView(),
      ),
    );
  }

  Widget _buildJoinView() {
    final hosts = _hosts.values.toList()
      ..sort((a, b) => b.seenAt.compareTo(a.seenAt));

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (hosts.isNotEmpty) ...[
          const Text(
            'Parties found on your Wi-Fi',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Color(0xFF34D399),
            ),
          ),
          const SizedBox(height: 8),
          ...hosts.map(
            (h) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: 56,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _connecting
                      ? null
                      : () => _connectTo(
                            h.ip,
                            httpPort: h.httpPort,
                            udpPort: h.udpPort,
                          ),
                  icon: const Icon(Icons.wifi_tethering_rounded),
                  label: Text(
                    'Join ${h.hostName}  •  ${h.ip}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF151926),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                _scanning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find_rounded, color: Colors.white54),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _scanning
                        ? 'Searching your Wi-Fi for the Host phone...'
                        : 'No party found yet. Ask the Host to keep the "Party Host" screen open, then tap Search again.',
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _scanning ? null : _sweepSubnet,
            icon: const Icon(Icons.radar_rounded),
            label: const Text('Search Again'),
          ),
          const SizedBox(height: 16),
        ],

        if (_showScanner && _cameraGranted)
          Container(
            height: 260,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: const Color(0xFF151926),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _scannerController,
                  onDetect: _onQrDetected,
                  errorBuilder: (context, error) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Camera unavailable: ${error.errorDetails?.message ?? error.errorCode.name}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                IgnorePointer(
                  child: Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFF6366F1),
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (!_checkingCamera)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF151926),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.videocam_off_rounded,
                  size: 34,
                  color: Colors.white38,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Camera not available — no problem. Use the party list above or type the Host IP below.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await openAppSettings();
                  },
                  child: const Text('Open App Permissions'),
                ),
              ],
            ),
          ),

        const SizedBox(height: 16),
        const Text(
          'Or type the Host IP shown on the Host phone',
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _manualController,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: 'e.g. 192.168.1.5',
                  filled: true,
                  fillColor: const Color(0xFF151926),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                onSubmitted: (v) => _connectTo(v),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 50,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed:
                    _connecting ? null : () => _connectTo(_manualController.text),
                child: _connecting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Join'),
              ),
            ),
          ],
        ),

        if (_joinError != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x33EF4444),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _joinError!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5)),
            ),
          ),
        ],

        const SizedBox(height: 18),
        if (_myIps.isNotEmpty)
          Text(
            'Your Wi-Fi IP: ${_myIps.join(", ")}',
            style: const TextStyle(fontSize: 11, color: Colors.white30),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 6),
        const Text(
          'Both phones must be on the same Wi-Fi. If they cannot connect, turn on the Host phone\'s Personal Hotspot and join it from this phone.',
          style: TextStyle(fontSize: 11, color: Colors.white30),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildConnectedPlayerView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF151926),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: _roomPlaying
                      ? const Color(0x2210B981)
                      : const Color(0x226366F1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _roomPlaying
                      ? Icons.graphic_eq_rounded
                      : Icons.headphones_rounded,
                  size: 44,
                  color: _roomPlaying
                      ? const Color(0xFF34D399)
                      : const Color(0xFF818CF8),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                _songTitle,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              if (_downloading) ...[
                LinearProgressIndicator(
                  value: _downloadPercent / 100.0,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF6366F1),
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(height: 10),
                Text(
                  'Loading song... $_downloadPercent%',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ] else if (_readyInRam) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x2210B981),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    _roomPlaying
                        ? 'Playing in Sync'
                        : 'Ready — Waiting for Host',
                    style: const TextStyle(
                      color: Color(0xFF34D399),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ] else ...[
                const Text(
                  'Connected! Waiting for host to pick an MP3...',
                  style: TextStyle(color: Colors.white60, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 28),
              TextButton.icon(
                onPressed: _handleDisconnected,
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Leave Party'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
