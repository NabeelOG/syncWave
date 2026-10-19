import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const int _defaultHttpPort = 8080;
  static const int _udpPort = 8081;

  final AudioPlayer _player = AudioPlayer();
  HttpServer? _httpServer;
  RawDatagramSocket? _udpSocket;
  final Map<String, ConnectedFriend> _friends = {};

  List<String> _hostIps = <String>[];
  int _httpPort = _defaultHttpPort;
  bool _serverReady = false;
  String? _serverError;

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
  Timer? _beaconTimer;
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
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _keepInSync(),
    );
  }

  Future<void> _startServer() async {
    try {
      // 1. Start the HTTP server immediately (do not wait for IP detection).
      _httpServer = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _defaultHttpPort,
      );
      _httpPort = _defaultHttpPort;

      if (mounted) setState(() => _serverReady = true);
      _wireHttpHandler(_httpServer!);

      // 2. Detect IP addresses and start discovery beacons.
      final ips = await detectLanIps();
      if (!mounted) return;
      setState(() => _hostIps = ips);

      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
      );
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final dg = _udpSocket!.receive();
        if (dg == null) return;

        final double t2 = MonotonicClock.nowMs();
        final String msg = utf8.decode(dg.data, allowMalformed: true);

        if (msg.startsWith('PING,')) {
          final String t1Str = msg.substring(5);
          final String t3Str = MonotonicClock.nowMs().toStringAsFixed(3);
          final List<int> reply =
              utf8.encode('PONG,$t1Str,${t2.toStringAsFixed(3)},$t3Str');
          _udpSocket!.send(reply, dg.address, dg.port);
        } else if (msg.startsWith('DISCOVER_SYNCWAVE')) {
          _sendBeaconTo(dg.address, dg.port);
        }
      });

      _beaconTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_udpSocket == null || _hostIps.isEmpty) return;
        try {
          _udpSocket!.send(
            _beaconPacket(),
            InternetAddress('255.255.255.255'),
            8082,
          );
          for (final ip in _hostIps) {
            final parts = ip.split('.');
            if (parts.length == 4) {
              _udpSocket!.send(
                _beaconPacket(),
                InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'),
                8082,
              );
            }
          }
        } catch (_) {}
      });
    } catch (e) {
      if (mounted) setState(() => _serverError = e.toString());
    }
  }

  List<int> _beaconPacket() {
    return utf8.encode(
      'SYNCWAVE_HOST,${widget.deviceName},'
      '${_hostIps.isNotEmpty ? _hostIps.first : ''},'
      '$_httpPort,$_udpPort',
    );
  }

  void _sendBeaconTo(InternetAddress address, int port) {
    try {
      _udpSocket?.send(_beaconPacket(), address, port);
    } catch (_) {}
  }

  void _wireHttpHandler(HttpServer server) {
    server.listen((HttpRequest req) async {
      try {
        req.response.headers.add('Access-Control-Allow-Origin', '*');
        req.response.headers.add('Access-Control-Allow-Headers', '*');

        if (req.uri.path == '/ping') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'app': 'syncwave',
            'hostName': widget.deviceName,
            'ip': _hostIps.isNotEmpty ? _hostIps.first : '',
            'httpPort': _httpPort,
            'udpPort': _udpPort,
          }));
          await req.response.close();
          return;
        }

        if (req.uri.path == '/ws' &&
            WebSocketTransformer.isUpgradeRequest(req)) {
          final WebSocket ws = await WebSocketTransformer.upgrade(req);
          final String id = 'f_${DateTime.now().microsecondsSinceEpoch % 100000}';
          final friend = ConnectedFriend(
            id: id,
            socket: ws,
            name: 'Friend ${_friends.length + 1}',
          );
          if (mounted) setState(() => _friends[id] = friend);

          if (_mp3Bytes != null) {
            final String hostHeader =
                req.headers.value(HttpHeaders.hostHeader) ??
                    '$_httpPort';
            ws.add(jsonEncode({
              'type': 'LOAD_TRACK',
              'trackId': _trackId,
              'title': _songTitle,
              'size': _mp3Bytes!.length,
              'url': 'http://$hostHeader/track.mp3?id=$_trackId',
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
          return;
        }

        if (req.uri.path == '/track.mp3' && _mp3Bytes != null) {
          req.response.headers.contentType = ContentType('audio', 'mpeg');
          req.response.headers.contentLength = _mp3Bytes!.length;
          req.response.add(_mp3Bytes!);
          await req.response.close();
          return;
        }

        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      } catch (_) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
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
          if (msg['name'] != null &&
              (msg['name'] as String).trim().isNotEmpty) {
            friend.name = msg['name'] as String;
          }
          if (msg['readyInRam'] != null) {
            friend.ready = msg['readyInRam'] as bool;
          }
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
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'm4a', 'aac'],
      );
    } catch (_) {
      picked = null;
    }
    if (picked == null) return;

    final PlatformFile chosen = picked;
    final String fileName = chosen.name;
    final String? localPath = chosen.path;

    Uint8List bytes;
    try {
      bytes = await chosen.readAsBytes();
    } catch (_) {
      return;
    }
    if (bytes.isEmpty) return;

    await _player.stop();
    final String newId = 'song_${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _isPlaying = false;
      _mp3Bytes = bytes;
      _songTitle = fileName;
      _trackId = newId;
      for (final f in _friends.values) {
        f.ready = false;
        f.progress = 0;
      }
    });

    try {
      await _player.setAudioSource(RamAudioSource(bytes));
    } catch (_) {
      if (localPath != null) {
        try {
          await _player.setFilePath(localPath);
        } catch (_) {}
      }
    }

    _broadcast({
      'type': 'LOAD_TRACK',
      'trackId': newId,
      'title': fileName,
      'size': bytes.length,
      'url': 'http://${_hostIps.isNotEmpty ? _hostIps.first : '0.0.0.0'}:$_httpPort/track.mp3?id=$newId',
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
    final double elapsedSec =
        (MonotonicClock.nowMs() - _startHostTimeMs) / 1000.0;
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
    _beaconTimer?.cancel();
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
    final String primaryIp = _hostIps.isNotEmpty ? _hostIps.first : '';
    final String qrData = 'syncwave://$primaryIp:$_httpPort:$_udpPort';

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
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF151926),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  const Text(
                    'Scan or Tap to Join Party',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Friends open SyncWave → Join a Party. Your party appears automatically on the same Wi-Fi.',
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
                    child: _serverReady && primaryIp.isNotEmpty
                        ? QrImageView(
                            data: qrData,
                            version: QrVersions.auto,
                            size: 170,
                            backgroundColor: Colors.white,
                          )
                        : SizedBox(
                            width: 170,
                            height: 170,
                            child: Center(
                              child: _serverError != null
                                  ? Text(
                                      'Server error:\n$_serverError',
                                      style: const TextStyle(
                                        color: Colors.red,
                                        fontSize: 11,
                                      ),
                                      textAlign: TextAlign.center,
                                    )
                                  : const CircularProgressIndicator(),
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  if (primaryIp.isNotEmpty)
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(
                          text: '$primaryIp:$_httpPort',
                        ));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Host IP copied'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E2436),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'Host IP: $primaryIp',
                              style: const TextStyle(
                                color: Color(0xFF818CF8),
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Tap to copy — share with friends',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_hostIps.length > 1) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Other addresses: ${_hostIps.skip(1).join(', ')}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 10),
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
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                        Text(
                          _formatTime(_duration),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
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
                        _isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
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

            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Tip: If friends cannot find you, turn on your phone\'s Personal Hotspot and ask them to join it. '
                'Some Wi-Fi networks block phone-to-phone connections.',
                style: TextStyle(fontSize: 12, color: Colors.white38),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
