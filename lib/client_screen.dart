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

  const DiscoveredHost({
    required this.hostName,
    required this.ip,
    required this.httpPort,
    required this.udpPort,
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
  final TextEditingController _manualIpController = TextEditingController();
  MobileScannerController? _scannerController;

  bool _cameraPermissionGranted = false;
  bool _checkingCamera = true;

  WebSocket? _ws;
  RawDatagramSocket? _udpSocket;
  RawDatagramSocket? _discoverySocket;
  String? _hostIp;
  int _httpPort = 8080;
  int _udpPort = 8081;

  bool _connected = false;
  bool _connecting = false;
  final Map<String, DiscoveredHost> _discoveredHosts = {};

  // Song State
  String _songTitle = 'Waiting for host to pick a song...';
  bool _readyInRam = false;
  bool _downloading = false;
  int _downloadPercent = 0;

  // Playback State
  bool _roomPlaying = false;
  double _startHostTimeMs = 0.0;
  double _startTrackPosSec = 0.0;
  double _currentRate = 1.0;

  Timer? _syncTimer;
  Timer? _heartbeatTimer;
  Timer? _discoveryProbeTimer;
  Timer? _scheduledStartTimer;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initCameraAndDiscovery();
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _keepInSync(),
    );
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _sendBackgroundSyncAndStatus(),
    );
  }

  Future<void> _initCameraAndDiscovery() async {
    // 1. Start automatic Wi-Fi discovery immediately (even before camera opens)
    _startWifiAutoDiscovery();

    // 2. Request Camera permission explicitly so MobileScanner never starts black
    final PermissionStatus status = await Permission.camera.request();
    if (!mounted) return;

    if (status.isGranted) {
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
      );
      setState(() {
        _cameraPermissionGranted = true;
        _checkingCamera = false;
      });
    } else {
      setState(() {
        _cameraPermissionGranted = false;
        _checkingCamera = false;
      });
    }
  }

  Future<void> _startWifiAutoDiscovery() async {
    // A. Listen for UDP beacons from Host on port 8082
    try {
      _discoverySocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8082,
        reuseAddress: true,
      );
      _discoverySocket!.broadcastEnabled = true;
      _discoverySocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = _discoverySocket!.receive();
          if (dg == null) return;
          final String msg = utf8.decode(dg.data);
          if (msg.startsWith('SYNCWAVE_HOST,')) {
            final List<String> parts = msg.split(',');
            if (parts.length >= 5) {
              final String hostName = parts[1];
              // Prefer the sender's actual UDP packet source IP if valid
              final String senderIp = dg.address.address;
              final String reportedIp = parts[2];
              final String bestIp =
                  (senderIp.isNotEmpty && senderIp != '0.0.0.0')
                      ? senderIp
                      : reportedIp;
              final int httpP = int.tryParse(parts[3]) ?? 8080;
              final int udpP = int.tryParse(parts[4]) ?? 8081;

              if (mounted) {
                setState(() {
                  _discoveredHosts[bestIp] = DiscoveredHost(
                    hostName: hostName,
                    ip: bestIp,
                    httpPort: httpP,
                    udpPort: udpP,
                  );
                });
              }
            }
          }
        }
      });

      // Actively broadcast DISCOVER_SYNCWAVE probe every 2s
      _discoveryProbeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_connected || _discoverySocket == null) return;
        try {
          _discoverySocket!.send(
            utf8.encode('DISCOVER_SYNCWAVE'),
            InternetAddress('255.255.255.255'),
            8081,
          );
        } catch (_) {}
      });
    } catch (_) {}

    // B. Fast parallel HTTP /24 subnet sweep (finds Host even if router blocks UDP broadcast)
    _scanLocalSubnetForHost();
  }

  Future<void> _scanLocalSubnetForHost() async {
    final String myIp = await detectLocalWifiIp();
    final List<String> octets = myIp.split('.');
    if (octets.length != 4) return;
    final String prefix = '${octets[0]}.${octets[1]}.${octets[2]}';

    // Also check common Android hotspot gateway IPs (192.168.43.1, 192.168.137.1)
    final List<String> candidates = <String>[
      '192.168.43.1',
      '192.168.137.1',
      for (int i = 1; i <= 254; i++) '$prefix.$i',
    ];

    const int batchSize = 35;
    for (int i = 0; i < candidates.length; i += batchSize) {
      if (!mounted || _connected) return;
      final batch = candidates.skip(i).take(batchSize);
      await Future.wait(batch.map(_probeHostHttp));
    }
  }

  Future<void> _probeHostHttp(String ip) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 450);
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse('http://$ip:8080/ping'));
      final HttpClientResponse resp =
          await req.close().timeout(const Duration(milliseconds: 500));
      if (resp.statusCode == 200) {
        final String body = await resp.transform(utf8.decoder).join();
        final Map<String, dynamic> data =
            jsonDecode(body) as Map<String, dynamic>;
        if (data['app'] == 'syncwave' && mounted) {
          setState(() {
            _discoveredHosts[ip] = DiscoveredHost(
              hostName: (data['hostName'] as String?) ?? 'Party Host',
              ip: ip,
              httpPort: (data['httpPort'] as num?)?.toInt() ?? 8080,
              udpPort: (data['udpPort'] as num?)?.toInt() ?? 8081,
            );
          });
        }
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  void _onQrDetected(BarcodeCapture capture) {
    if (_connected || _connecting) return;
    for (final barcode in capture.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw == null) continue;
      if (raw.startsWith('syncwave://')) {
        final String stripped = raw.replaceFirst('syncwave://', '').trim();
        final List<String> parts = stripped.split(':');
        if (parts.isNotEmpty) {
          final String ip = parts[0];
          final int httpP =
              parts.length > 1 ? (int.tryParse(parts[1]) ?? 8080) : 8080;
          final int udpP =
              parts.length > 2 ? (int.tryParse(parts[2]) ?? 8081) : 8081;
          _connectToHost(ip, httpPort: httpP, udpPort: udpP);
          break;
        }
      }
    }
  }

  Future<void> _connectToHost(
    String rawIpInput, {
    int httpPort = 8080,
    int udpPort = 8081,
  }) async {
    // Sanitize IP input (strip http://, ws://, :8080, slashes, whitespace)
    String cleanIp = rawIpInput
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^wss?://'), '')
        .split('/')
        .first;
    if (cleanIp.contains(':')) {
      final parts = cleanIp.split(':');
      cleanIp = parts[0].trim();
      httpPort = int.tryParse(parts[1].trim()) ?? httpPort;
    }

    if (_connecting || cleanIp.isEmpty) return;
    setState(() {
      _connecting = true;
      _hostIp = cleanIp;
      _httpPort = httpPort;
      _udpPort = udpPort;
    });

    try {
      _clockFilter.reset();

      _udpSocket?.close();
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = _udpSocket!.receive();
          if (dg == null) return;
          final double t4 = MonotonicClock.nowMs();
          final List<String> parts = utf8.decode(dg.data).split(',');
          if (parts.length == 4 && parts[0] == 'PONG') {
            final double? t1 = double.tryParse(parts[1]);
            final double? t2 = double.tryParse(parts[2]);
            final double? t3 = double.tryParse(parts[3]);
            if (t1 != null && t2 != null && t3 != null) {
              _clockFilter.addSample(t1, t2, t3, t4);
            }
          }
        }
      });

      final WebSocket ws = await WebSocket.connect(
        'ws://$cleanIp:$httpPort/ws',
      ).timeout(const Duration(seconds: 6));

      _ws = ws;
      _scannerController?.stop();

      if (mounted) {
        setState(() {
          _connected = true;
          _connecting = false;
        });
      }

      ws.listen(
        (dynamic data) => _handleHostMessage(data as String),
        onDone: _handleDisconnected,
        onError: (_) => _handleDisconnected(),
      );

      _runInitialSyncBurst(cleanIp, udpPort);
      _sendStatusUpdate();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connected = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not reach $cleanIp. Make sure both phones are on the same Wi-Fi or Hotspot.',
            ),
          ),
        );
      }
    }
  }

  void _handleDisconnected() {
    _scheduledStartTimer?.cancel();
    _player.stop();
    _scannerController?.start();
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
    final InternetAddress? dest = InternetAddress.tryParse(hostIp);
    for (int i = 0; i < 25; i++) {
      if (!_connected) break;
      final double t1 = MonotonicClock.nowMs();
      if (dest != null) {
        _udpSocket?.send(
          utf8.encode('PING,${t1.toStringAsFixed(3)}'),
          dest,
          udpPort,
        );
      }
      _ws?.add(jsonEncode({'type': 'SYNC_PING', 't1': t1}));
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  void _sendBackgroundSyncAndStatus() {
    if (!_connected || _hostIp == null) return;
    final double t1 = MonotonicClock.nowMs();
    final InternetAddress? dest = InternetAddress.tryParse(_hostIp!);
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
    final double t4 = MonotonicClock.nowMs();
    final Map<String, dynamic> msg = jsonDecode(raw) as Map<String, dynamic>;
    final String? type = msg['type'] as String?;

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
        final String trackId = (msg['trackId'] as String?) ?? '';
        // Always use the known working _hostIp to download the MP3
        final String downloadUrl =
            'http://$_hostIp:$_httpPort/track.mp3?id=$trackId';
        final String title = (msg['title'] as String?) ?? 'Shared Song';
        final int expectedSize = (msg['size'] as num?)?.toInt() ?? 0;
        await _downloadSongIntoRam(downloadUrl, title, expectedSize);
        break;

      case 'PLAY_AT':
        final double startServerMs =
            (msg['startServerTimeMs'] as num).toDouble();
        final double startPosSec = (msg['startTrackPosSec'] as num).toDouble();
        await _executeScheduledPlay(startServerMs, startPosSec);
        break;

      case 'PAUSE':
        _scheduledStartTimer?.cancel();
        final double posSec = (msg['posSec'] as num).toDouble();
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
      final HttpClient client = HttpClient();
      final HttpClientRequest req = await client.getUrl(Uri.parse(url));
      final HttpClientResponse resp = await req.close();

      final int totalBytes =
          resp.contentLength > 0 ? resp.contentLength : expectedSize;
      final BytesBuilder builder = BytesBuilder(copy: false);
      int received = 0;

      await for (final List<int> chunk in resp) {
        builder.add(chunk);
        received += chunk.length;
        if (totalBytes > 0) {
          final int pct = ((received / totalBytes) * 100).clamp(0, 99).round();
          if (pct != _downloadPercent && mounted) {
            setState(() => _downloadPercent = pct);
            _sendStatusUpdate();
          }
        }
      }

      final Uint8List ramBytes = builder.takeBytes();
      await _player.setAudioSource(RamAudioSource(ramBytes));

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

    final double hostNowMs = _clockFilter.estimatedHostNowMs();
    final double waitMs = startServerTimeMs - hostNowMs;

    if (waitMs > 0) {
      await _player.seek(Duration(milliseconds: (startPosSec * 1000).round()));
      _scheduledStartTimer = Timer(
        Duration(microseconds: (waitMs * 1000).round()),
        () => _player.play(),
      );
    } else {
      final double catchUpSec = startPosSec + (-waitMs / 1000.0);
      await _player.seek(Duration(milliseconds: (catchUpSec * 1000).round()));
      _player.play();
    }
  }

  void _keepInSync() {
    if (!_roomPlaying || !_player.playing || !_readyInRam) return;

    final double hostNowMs = _clockFilter.estimatedHostNowMs();
    final double elapsedSec = (hostNowMs - _startHostTimeMs) / 1000.0;
    if (elapsedSec < 0.25) return;

    final double expectedMs = (_startTrackPosSec + elapsedSec) * 1000.0;
    final double actualMs = _player.position.inMilliseconds.toDouble();

    final PllDecision d = PllController.evaluate(
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
    _discoveryProbeTimer?.cancel();
    _scheduledStartTimer?.cancel();
    _scannerController?.dispose();
    _ws?.close();
    _udpSocket?.close();
    _discoverySocket?.close();
    _manualIpController.dispose();
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
        child: _connected ? _buildConnectedPlayerView() : _buildScannerView(),
      ),
    );
  }

  Widget _buildScannerView() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Auto-Discovered Parties on Wi-Fi (One-Tap Join!)
          if (_discoveredHosts.isNotEmpty) ...[
            const Text(
              'Parties Found on Wi-Fi (Tap to Join):',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF34D399),
              ),
            ),
            const SizedBox(height: 8),
            ..._discoveredHosts.values.map(
              (h) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                      vertical: 14,
                      horizontal: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => _connectToHost(
                    h.ip,
                    httpPort: h.httpPort,
                    udpPort: h.udpPort,
                  ),
                  icon: const Icon(Icons.wifi_tethering_rounded),
                  label: Text(
                    'Join ${h.hostName} (${h.ip})',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // 2. Camera QR Scanner
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_checkingCamera)
                    Container(
                      color: const Color(0xFF151926),
                      child: const Center(child: CircularProgressIndicator()),
                    )
                  else if (_cameraPermissionGranted &&
                      _scannerController != null)
                    MobileScanner(
                      controller: _scannerController!,
                      onDetect: _onQrDetected,
                    )
                  else
                    Container(
                      color: const Color(0xFF151926),
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.videocam_off_rounded,
                            size: 48,
                            color: Colors.white54,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Camera permission is needed to scan QR codes',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () async {
                              await openAppSettings();
                            },
                            child: const Text('Enable Camera Permission'),
                          ),
                        ],
                      ),
                    ),
                  if (_cameraPermissionGranted)
                    Container(
                      width: 210,
                      height: 210,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0xFF6366F1),
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  if (_connecting)
                    Container(
                      color: Colors.black54,
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 3. Manual IP Entry + Re-scan Wi-Fi button
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualIpController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: 'Host IP (shown under Host QR)',
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
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Search Wi-Fi for Party',
                onPressed: _scanLocalSubnetForHost,
                icon: const Icon(Icons.radar_rounded),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 15,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () =>
                    _connectToHost(_manualIpController.text.trim()),
                child: const Text('Join'),
              ),
            ],
          ),
        ],
      ),
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
                    _roomPlaying ? 'Playing in Sync' : 'Ready — Waiting for Host',
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
