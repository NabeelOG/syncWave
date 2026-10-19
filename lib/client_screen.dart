import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'clock_sync.dart';
import 'ram_audio_source.dart';

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

  WebSocket? _ws;
  RawDatagramSocket? _udpSocket;
  String? _hostIp;
  int _httpPort = 8080;
  int _udpPort = 8081;

  bool _connected = false;
  bool _connecting = false;

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
  Timer? _scheduledStartTimer;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _keepInSync(),
    );
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _sendBackgroundSyncAndStatus(),
    );
  }

  void _onQrDetected(BarcodeCapture capture) {
    if (_connected || _connecting) return;
    for (final barcode in capture.barcodes) {
      final String? raw = barcode.rawValue;
      if (raw == null) continue;
      // Expected format: syncwave://<ip>:8080:8081
      if (raw.startsWith('syncwave://')) {
        final String stripped = raw.replaceFirst('syncwave://', '');
        final List<String> parts = stripped.split(':');
        if (parts.isNotEmpty) {
          final String ip = parts[0];
          final int httpP = parts.length > 1 ? (int.tryParse(parts[1]) ?? 8080) : 8080;
          final int udpP = parts.length > 2 ? (int.tryParse(parts[2]) ?? 8081) : 8081;
          _connectToHost(ip, httpPort: httpP, udpPort: udpP);
          break;
        }
      }
    }
  }

  Future<void> _connectToHost(
    String hostIp, {
    int httpPort = 8080,
    int udpPort = 8081,
  }) async {
    if (_connecting || hostIp.isEmpty) return;
    setState(() {
      _connecting = true;
      _hostIp = hostIp;
      _httpPort = httpPort;
      _udpPort = udpPort;
    });

    try {
      _clockFilter.reset();

      // Bind UDP socket for silent background clock sync
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
        'ws://$hostIp:$httpPort/ws',
      ).timeout(const Duration(seconds: 6));

      _ws = ws;
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

      // Run initial 25-probe clock sync burst silently
      _runInitialSyncBurst(hostIp, udpPort);
      _sendStatusUpdate();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connected = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not connect to $hostIp')),
        );
      }
    }
  }

  void _handleDisconnected() {
    _scheduledStartTimer?.cancel();
    _player.stop();
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
    final InternetAddress dest = InternetAddress(hostIp);
    for (int i = 0; i < 25; i++) {
      if (!_connected) break;
      final double t1 = MonotonicClock.nowMs();
      _udpSocket?.send(
        utf8.encode('PING,${t1.toStringAsFixed(3)}'),
        dest,
        udpPort,
      );
      _ws?.add(jsonEncode({'type': 'SYNC_PING', 't1': t1}));
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  void _sendBackgroundSyncAndStatus() {
    if (!_connected || _hostIp == null) return;
    final double t1 = MonotonicClock.nowMs();
    try {
      _udpSocket?.send(
        utf8.encode('PING,${t1.toStringAsFixed(3)}'),
        InternetAddress(_hostIp!),
        _udpPort,
      );
    } catch (_) {}
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
        'rttMs': _clockFilter.minRttMs < 9000 ? _clockFilter.minRttMs : 0.0,
        'driftMs': 0.0,
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
        final String url = msg['url'] as String;
        final String title = (msg['title'] as String?) ?? 'Shared Song';
        final int expectedSize = (msg['size'] as num?)?.toInt() ?? 0;
        await _downloadSongIntoRam(url, title, expectedSize);
        break;

      case 'PLAY_AT':
        final double startServerMs = (msg['startServerTimeMs'] as num).toDouble();
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

  /// Downloads the MP3 over local Wi-Fi directly into a [Uint8List] in RAM
  /// and prepares the audio player for instant playback.
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
    _scheduledStartTimer?.cancel();
    _ws?.close();
    _udpSocket?.close();
    _manualIpController.dispose();
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_connected ? 'Party Speaker' : 'Scan Host QR'),
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
        children: [
          const Text(
            'Point camera at your friend\'s QR code',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  MobileScanner(onDetect: _onQrDetected),
                  Container(
                    width: 220,
                    height: 220,
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualIpController,
                  decoration: InputDecoration(
                    hintText: 'Or enter Host IP (e.g. 192.168.1.5)',
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
              const SizedBox(width: 10),
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
                  'Loading song into memory... $_downloadPercent%',
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
