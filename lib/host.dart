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

import 'device_audio.dart';
import 'lan.dart';
import 'ram_source.dart';
import 'sync.dart';

class Peer {
  final WebSocket socket;
  String name;
  String version;
  bool ready;
  int progress;
  double errorMs;
  Peer(this.socket, this.name)
      : version = '',
        ready = false,
        progress = 0,
        errorMs = 0;
}

class HostScreen extends StatefulWidget {
  final String deviceName;
  const HostScreen({super.key, required this.deviceName});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  final AudioPlayer _player = AudioPlayer();
  final PositionTracker _position = PositionTracker();
  final Map<String, Peer> _peers = {};

  HttpServer? _server;
  List<String> _ips = [];
  int _ipIndex = 0;
  int _peerCounter = 0;
  String _hostIp = '';
  String? _error;
  bool _playing = false;

  Uint8List? _song;
  String _songName = 'No song selected';
  String _songType = 'audio/mpeg';
  String _trackId = '';
  Duration _positionUi = Duration.zero;
  Duration _duration = Duration.zero;

  double _startAtMs = 0;
  double _startPosSec = 0;
  double _speed = 1.0;
  double _lastSeekAtMs = 0;

  // Estimated latency between the player emitting a sample and the sound
  // leaving this phone's speaker. Clients use it together with their own value
  // to line the two phones up.
  double _outputLatencyMs = 0;

  Timer? _pll;
  Timer? _startTimer;
  Timer? _syncTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;

  // Filtered phase error used by the proportional correction.

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _posSub = _player.positionStream.listen((p) {
      _position.sync(p.inMilliseconds.toDouble());
      if (mounted) setState(() => _positionUi = p);
    });
    _durSub = _player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    });
    _start();
    _pll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _keepInSync(),
    );
  }

  Future<void> _start() async {
    try {
      // Bind first so friends can connect immediately; the latency
      // measurement runs in the background and is published from then on.
      final server = await HttpServer.bind(InternetAddress.anyIPv4, kPort);
      _server = server;
      server.listen(_handleRequest);

      DeviceAudio.outputLatencyMs().then((ms) {
        if (mounted && ms > 0) setState(() => _outputLatencyMs = ms);
      });

      final ips = await lanIps();
      if (mounted) {
        setState(() {
          _ips = ips;
          _hostIp = ips.isNotEmpty ? ips.first : '';
        });
      }

      // Publish the actual playhead so the clients follow what this phone is
      // really playing. This is the only thing the clients need to stay in
      // sync - no shared schedule, no clock games.
      _syncTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        _broadcast({
          'type': 'sync',
          'posMs': _position.positionMs,
          'atMs': Monotonic.nowMs(),
        });
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final path = req.uri.path;

    if (path == '/ping') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'app': 'syncwave',
        'name': widget.deviceName,
        'ip': _hostIp,
        'port': kPort,
        'latencyMs': _outputLatencyMs,
      }));
      await req.response.close();
      return;
    }

    if (path == '/track.mp3' && _song != null) {
      final song = _song!;
      req.response.headers.contentType =
          ContentType.parse(_songType);
      req.response.headers.contentLength = song.length;
      req.response.add(song);
      await req.response.close();
      return;
    }

    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      final id = 'p${DateTime.now().microsecondsSinceEpoch % 100000}';
      final peer = Peer(ws, 'Friend ${_peerCounter + 1}');
      _peerCounter++;
      if (mounted) setState(() => _peers[id] = peer);

      ws.listen(
        (data) => _onPeerMessage(peer, data as String),
        onDone: () {
          if (mounted) setState(() => _peers.remove(id));
        },
        onError: (_) {
          if (mounted) setState(() => _peers.remove(id));
        },
      );

      // Send the current state so a phone that joins late still gets the song
      // and starts in sync with everybody else.
      _sendStateTo(peer);
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  void _onPeerMessage(Peer peer, String raw) {
    final t2 = Monotonic.nowMs();
    final msg = jsonDecode(raw) as Map<String, dynamic>;

    switch (msg['type']) {
      case 'ping':
        peer.socket.add(jsonEncode({
          'type': 'pong',
          't1': msg['t1'],
          't2': t2,
          't3': Monotonic.nowMs(),
        }));
        break;
      case 'hello':
        if (mounted) {
          final name = (msg['name'] as String?)?.trim();
          final version = (msg['version'] as String?)?.trim();
          setState(() {
            if (name != null && name.isNotEmpty) peer.name = name;
            if (version != null) peer.version = version;
          });
        }
        break;
      case 'status':
        if (mounted) {
          setState(() {
            peer.ready = msg['ready'] == true;
            peer.progress = (msg['progress'] as num?)?.toInt() ?? 0;
            peer.errorMs = (msg['errorMs'] as num?)?.toDouble() ?? 0.0;
          });
        }
        break;
    }
  }

  void _broadcast(Map<String, dynamic> msg) {
    final data = jsonEncode(msg);
    for (final p in _peers.values) {
      p.socket.add(data);
    }
  }

  /// Sends the current song (and the current playback position) to a peer
  /// that just connected, so late joiners are in sync too.
  void _sendStateTo(Peer peer) {
    final song = _song;
    if (song != null) {
      peer.socket.add(jsonEncode({
        'type': 'load',
        'trackId': _trackId,
        'title': _songName,
        'size': song.length,
      }));
    }
    if (_playing) {
      peer.socket.add(jsonEncode({
        'type': 'play',
        'startAtMs': Monotonic.nowMs(),
        'startPosSec': _position.positionMs / 1000.0,
      }));
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

    final file = picked;
    final String name = file.name;
    final String? path = file.path;

    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return;
    }
    if (bytes.isEmpty) return;

    await _player.stop();
    final String trackId = 't${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _song = bytes;
      _songName = name;
      _songType = audioContentType(name);
      _trackId = trackId;
      _playing = false;
      for (final p in _peers.values) {
        p.ready = false;
        p.progress = 0;
      }
    });

    try {
      await _player.setAudioSource(RamSource(bytes, contentType: _songType));
    } catch (_) {
      if (path != null) {
        try {
          await _player.setFilePath(path);
        } catch (_) {}
      }
    }

    // Pre-roll: park the decoder at 0 and wait until it is ready, so pressing
    // play does not have to seek (and does not start late).
    try {
      await _player.seek(Duration.zero);
      _position.reset(0);
      await _player.processingStateStream
          .firstWhere((s) => s == ProcessingState.ready)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => _player.processingState,
          );
    } catch (_) {}

    _broadcast({
      'type': 'load',
      'trackId': trackId,
      'title': name,
      'size': bytes.length,
    });
  }

  Future<void> _play({double? fromSec}) async {
    if (_song == null) return;
    // Use the player's own position: _position is refreshed by positionStream
    // and can be a couple of hundred milliseconds behind.
    final double pos = fromSec ?? (_position.positionMs / 1000.0);
    final double startAt = Monotonic.nowMs() + 1500;

    _broadcast({
      'type': 'play',
      'startAtMs': startAt,
      'startPosSec': pos,
      'latencyMs': _outputLatencyMs,
    });

    _startTimer?.cancel();
    setState(() {
      _playing = true;
      _startAtMs = startAt;
      _startPosSec = pos;
    });

    await _player.pause();
    await _player.setSpeed(1.0);
    _speed = 1.0;

    // Skip the seek when the player is already at the target: seeking costs
    // 100-500 ms and every phone has to start at the same wall-clock moment.
    final int targetMs = (pos * 1000).round();
    if ((_position.positionMs.round() - targetMs).abs() > 30) {
      await _player.seek(Duration(milliseconds: targetMs));
    }
    _position.reset(targetMs.toDouble());

    final wait = startAt - Monotonic.nowMs();
    if (wait > 0) {
      _startTimer = Timer(
        Duration(microseconds: (wait * 1000).round()),
        () => _player.play(),
      );
    } else {
      // Already late: jump to where the room currently is.
      final int posMs = targetMs + (-wait).round();
      if ((_position.positionMs.round() - posMs).abs() > 30) {
        await _player.seek(Duration(milliseconds: posMs));
      }
      _position.reset(posMs.toDouble());
      _player.play();
    }
  }

  Future<void> _pause() async {
    _startTimer?.cancel();
    final double pos = _position.positionMs / 1000.0;
    setState(() => _playing = false);
    await _player.pause();
    _broadcast({'type': 'pause', 'posSec': pos});
  }

  void _keepInSync() {
    // The host is the reference: it does not chase anything, the clients
    // follow the playhead it publishes. Only a real stall is corrected here.
    if (!_playing || !_player.playing) return;
    final double elapsed = (Monotonic.nowMs() - _startAtMs) / 1000.0;
    if (elapsed < 0.5) return;

    final double expected = (_startPosSec + elapsed) * 1000.0;
    final double error = expected - _position.positionMs;

    if (Pll.needsHardSeek(error)) {
      final double now = Monotonic.nowMs();
      if (now - _lastSeekAtMs > 2000) {
        _lastSeekAtMs = now;
        _player.seek(Duration(milliseconds: expected.round()));
        _position.reset(expected);
      }
    }
  }

  /// Applies a target speed, but never changes it by more than
  /// [Pll.maxSpeedStep] at once: a step in the playback rate is audible.
  void _applySpeed(double target) {
    final double limited =
        (_speed + (target - _speed).clamp(-Pll.maxSpeedStep, Pll.maxSpeedStep))
            .clamp(0.97, 1.03);
    if ((limited - _speed).abs() < 0.00002) return;
    _speed = limited;
    _position.setSpeed(limited);
    _player.setSpeed(limited);
  }

  String _fmt(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _pll?.cancel();
    _startTimer?.cancel();
    _syncTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _server?.close(force: true);
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String qrData = 'syncwave://join?ip=$_hostIp';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Party Host'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // QR + host address
            Container(
              padding: const EdgeInsets.all(20),
              decoration: _card(),
              child: Column(
                children: [
                  const Text(
                    'Friends join with the SyncWave app',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: _hostIp.isEmpty
                        ? const SizedBox(
                            width: 170,
                            height: 170,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : QrImageView(
                            data: qrData,
                            size: 170,
                            backgroundColor: Colors.white,
                          ),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: _hostIp.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(
                              ClipboardData(text: _hostIp),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Host IP copied'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E2436),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _error != null
                            ? 'Server error: $_error'
                            : 'Host IP: ${_hostIp.isEmpty ? '...' : _hostIp}',
                        style: const TextStyle(
                          color: Color(0xFF818CF8),
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${_peers.length} connected',
                    style: const TextStyle(
                      color: Color(0xFF34D399),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_ips.length > 1) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'Sharing this address:',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: List.generate(_ips.length, (i) {
                        final selected = i == _ipIndex;
                        return ChoiceChip(
                          selected: selected,
                          label: Text(
                            _ips[i],
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                          onSelected: (_) => setState(() {
                            _ipIndex = i;
                            _hostIp = _ips[i];
                          }),
                        );
                      }),
                    ),
                  ],
                  if (_peers.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _peers.values.map((p) {
                        return Chip(
                          backgroundColor: const Color(0xFF1E2436),
                          avatar: Icon(
                            p.ready ? Icons.check_circle : Icons.downloading,
                            size: 18,
                            color: p.ready
                                ? const Color(0xFF34D399)
                                : const Color(0xFFFBBF24),
                          ),
                          label: Text(
                            p.ready
                                ? '${p.name} '
                                    '${p.errorMs >= 0 ? "+" : ""}'
                                    '${p.errorMs.toStringAsFixed(0)}ms'
                                    '${p.version.isNotEmpty && p.version != kAppVersion ? " ⚠ v${p.version}" : ""}'
                                : '${p.name} ${p.progress}%',
                            style: const TextStyle(fontSize: 12),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Player
            Container(
              padding: const EdgeInsets.all(22),
              decoration: _card(),
              child: Column(
                children: [
                  const Icon(
                    Icons.music_note_rounded,
                    size: 44,
                    color: Color(0xFF818CF8),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _songName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _pickSong,
                    icon: const Icon(Icons.library_music_rounded),
                    label: const Text('Choose MP3 from Phone'),
                  ),
                  Slider(
                    value: _positionUi.inMilliseconds
                        .toDouble()
                        .clamp(0, _duration.inMilliseconds.toDouble() + 1),
                    min: 0,
                    max: _duration.inMilliseconds > 0
                        ? _duration.inMilliseconds.toDouble()
                        : 1,
                    onChangeEnd: (ms) {
                      if (_song != null) _play(fromSec: ms / 1000.0);
                    },
                    onChanged: (ms) => setState(() {
                      _positionUi = Duration(milliseconds: ms.round());
                    }),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(_positionUi)),
                      Text(_fmt(_duration)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed:
                          _song == null ? null : () => _playing ? _pause() : _play(),
                      icon: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 26,
                      ),
                      label: Text(
                        _playing ? 'Pause' : 'Play on All Phones',
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
            const Text(
              'No connection? Turn on your phone\'s Personal Hotspot and have your friend join that network.',
              style: TextStyle(fontSize: 12, color: Colors.white38),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _card() => BoxDecoration(
        color: const Color(0xFF151926),
        borderRadius: BorderRadius.circular(22),
      );
}
