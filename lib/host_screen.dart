import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'clock_sync.dart';
import 'ram_audio_source.dart';

class ConnectedFriend {
  final String id;
  final WebSocket socket;
  String name;
  bool ready;
  int progress;

  ConnectedFriend({
    required this.id,
    required this.socket,
    required this.name,
    this.ready = false,
    this.progress = 0,
  });
}

class HostScreen extends StatefulWidget {
  final String deviceName;
  const HostScreen({super.key, required this.deviceName});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  static const int _httpPort = 8080;
  static const int _udpPort = 8081;

  final AudioPlayer _player = AudioPlayer();
  HttpServer? _httpServer;
  RawDatagramSocket? _udpSocket;
  final Map<String, ConnectedFriend> _friends = {};

  String _wifiIp = '';
  bool _serverReady = false;

  Uint8List? _mp3Bytes;
  String _songTitle = 'No song selected';
  String _trackId = '';
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  bool _isPlaying = false;
  double _startHostTimeMs = 0.0;
  double _startTrackPosSec = 0.0;
  double _currentRate = 1.0;

  Timer? _syncTimer;
  Timer? _scheduledPlayTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _posSub = _player.positionStream.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _durSub = _player.durationStream.listen((dur) {
      if (mounted && dur != null) setState(() => _duration = dur);
    });
    _startServer();
    // Silent background sync loop
    _syncTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _keepInSync());
  }

  Future<void> _startServer() async {
    final ip = await detectLocalWifiIp();
    if (mounted) setState(() => _wifiIp = ip);

    // Silent background UDP clock responder
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _udpPort);
    _udpSocket!.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final dg = _udpSocket!.receive();
        if (dg == null) return;
        final double t2 = MonotonicClock.nowMs();
        final String msg = utf8.decode(dg.data);
        if (msg.startsWith('PING,')) {
          final String t1Str = msg.substring(5);
          final String t3Str = MonotonicClock.nowMs().toStringAsFixed(3);
          final List<int> reply =
              utf8.encode('PONG,$t1Str,${t2.toStringAsFixed(3)},$t3Str');
          _udpSocket!.send(reply, dg.address, dg.port);
        }
      }
    });

    // HTTP + WebSocket Server for song sharing & play/pause commands
    _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, _httpPort);
    if (mounted) setState(() => _serverReady = true);

    _httpServer!.listen((HttpRequest req) async {
      if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        final WebSocket ws = await WebSocketTransformer.upgrade(req);
        final String id = 'f_${DateTime.now().microsecondsSinceEpoch % 10000}';
        final friend = ConnectedFriend(
          id: id,
          socket: ws,
          name: 'Friend ${_friends.length + 1}',
        );
        if (mounted) setState(() => _friends[id] = friend);

        if (_mp3Bytes != null) {
          ws.add(jsonEncode({
            'type': 'LOAD_TRACK',
            'trackId': _trackId,
            'title': _songTitle,
            'size': _mp3Bytes!.length,
            'url': 'http://$_wifiIp:$_httpPort/track.mp3?id=$_trackId',
          }));
        }

        ws.listen(
          (dynamic data) => _onFriendMessage(friend, data as String),
          onDone: () {
            if (mounted) setState(() => _friends.remove(id));
          },
          onError: (_) {
            if (mounted) setState(() => _friends.remove(id));
          },
        );
      } else if (req.uri.path == '/track.mp3' && _mp3Bytes != null) {
        req.response.headers.contentType = ContentType('audio', 'mpeg');
        req.response.headers.contentLength = _mp3Bytes!.length;
        req.response.add(_mp3Bytes!);
        await req.response.close();
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    });
  }

  void _onFriendMessage(ConnectedFriend friend, String raw) {
    final double t2 = MonotonicClock.nowMs();
    final Map<String, dynamic> msg = jsonDecode(raw) as Map<String, dynamic>;
    final String? type = msg['type'] as String?;

    if (type == 'SYNC_PING') {
      final double t3 = MonotonicClock.nowMs();
      friend.socket.add(jsonEncode({
        'type': 'SYNC_PONG',
        't1': msg['t1'],
        't2': t2,
        't3': t3,
      }));
    } else if (type == 'PEER_STATUS') {
      if (mounted) {
        setState(() {
          if (msg['name'] != null && (msg['name'] as String).trim().isNotEmpty) {
            friend.name = msg['name'] as String;
          }
          if (msg['readyInRam'] != null) friend.ready = msg['readyInRam'] as bool;
          if (msg['downloadPercent'] != null) {
            friend.progress = (msg['downloadPercent'] as num).toInt();
          }
        });
      }
    }
  }

  void _broadcast(Map<String, dynamic> msg) {
    final String data = jsonEncode(msg);
    for (final f in _friends.values) {
      try {
        f.socket.add(data);
      } catch (_) {}
    }
  }

  Future<void> _pickSong() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final PlatformFile file = result.files.first;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) return;

    await _player.stop();
    final String newId = 'song_${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _isPlaying = false;
      _mp3Bytes = bytes;
      _songTitle = file.name;
      _trackId = newId;
      for (final f in _friends.values) {
        f.ready = false;
        f.progress = 0;
      }
    });

    await _player.setAudioSource(RamAudioSource(bytes));

    _broadcast({
      'type': 'LOAD_TRACK',
      'trackId': newId,
      'title': file.name,
      'size': bytes.length,
      'url': 'http://$_wifiIp:$_httpPort/track.mp3?id=$newId',
    });
  }

  Future<void> _playAll({double? fromSec}) async {
    if (_mp3Bytes == null) return;
    final double posSec = fromSec ?? (_position.inMilliseconds / 1000.0);
    final double startAtMs = MonotonicClock.nowMs() + 1200.0;

    _broadcast({
      'type': 'PLAY_AT',
      'trackId': _trackId,
      'startServerTimeMs': startAtMs,
      'startTrackPosSec': posSec,
    });

    _scheduledPlayTimer?.cancel();
    setState(() {
      _isPlaying = true;
      _startHostTimeMs = startAtMs;
      _startTrackPosSec = posSec;
    });

    await _player.pause();
    await _player.setSpeed(1.0);
    _currentRate = 1.0;
    await _player.seek(Duration(milliseconds: (posSec * 1000).round()));

    final double waitMs = startAtMs - MonotonicClock.nowMs();
    if (waitMs > 0) {
      _scheduledPlayTimer = Timer(
        Duration(microseconds: (waitMs * 1000).round()),
        () => _player.play(),
      );
    } else {
      _player.play();
    }
  }

  Future<void> _pauseAll() async {
    _scheduledPlayTimer?.cancel();
    final double posSec = _player.position.inMilliseconds / 1000.0;
    setState(() => _isPlaying = false);
    await _player.pause();
    _broadcast({'type': 'PAUSE', 'posSec': posSec});
  }

  void _keepInSync() {
    if (!_isPlaying || !_player.playing) return;
    final double elapsedSec = (MonotonicClock.nowMs() - _startHostTimeMs) / 1000.0;
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

  String _formatTime(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _scheduledPlayTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _httpServer?.close(force: true);
    _udpSocket?.close();
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String qrData = 'syncwave://$_wifiIp:$_httpPort:$_udpPort';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Party Host'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          children: [
            // QR Code Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF151926),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  const Text(
                    'Scan to Join Party',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Friends on the same Wi-Fi can scan this QR code',
                    style: TextStyle(fontSize: 13, color: Colors.white60),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _serverReady
                        ? QrImageView(
                            data: qrData,
                            version: QrVersions.auto,
                            size: 180,
                            backgroundColor: Colors.white,
                          )
                        : const SizedBox(
                            width: 180,
                            height: 180,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '${_friends.length} ${_friends.length == 1 ? "friend" : "friends"} connected',
                    style: const TextStyle(
                      color: Color(0xFF34D399),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  if (_friends.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _friends.values.map((f) {
                        return Chip(
                          backgroundColor: const Color(0xFF1E2436),
                          avatar: Icon(
                            f.ready ? Icons.check_circle : Icons.downloading,
                            size: 18,
                            color: f.ready
                                ? const Color(0xFF34D399)
                                : const Color(0xFFFBBF24),
                          ),
                          label: Text(
                            f.ready ? f.name : '${f.name} (${f.progress}%)',
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Music Player Card
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: const Color(0xFF151926),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: const Color(0x226366F1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.music_note_rounded,
                      size: 36,
                      color: Color(0xFF818CF8),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _songTitle,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _pickSong,
                    icon: const Icon(Icons.library_music_rounded),
                    label: const Text('Choose MP3 from Phone'),
                  ),
                  const SizedBox(height: 20),

                  // Progress slider
                  Slider(
                    value: _position.inMilliseconds
                        .toDouble()
                        .clamp(0, _duration.inMilliseconds.toDouble() + 1),
                    min: 0,
                    max: _duration.inMilliseconds.toDouble() > 0
                        ? _duration.inMilliseconds.toDouble()
                        : 1.0,
                    onChangeEnd: (ms) {
                      if (_mp3Bytes != null) {
                        _playAll(fromSec: ms / 1000.0);
                      }
                    },
                    onChanged: (ms) {
                      setState(() {
                        _position = Duration(milliseconds: ms.round());
                      });
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatTime(_position),
                          style: const TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                        Text(
                          _formatTime(_duration),
                          style: const TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Big Play / Pause Button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _mp3Bytes == null
                          ? null
                          : () => _isPlaying ? _pauseAll() : _playAll(),
                      icon: Icon(
                        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 28,
                      ),
                      label: Text(
                        _isPlaying ? 'Pause' : 'Play on All Phones',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
