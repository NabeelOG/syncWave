import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'lan.dart';
import 'ram_source.dart';
import 'sync.dart';

class ClientScreen extends StatefulWidget {
  final String deviceName;
  final String? autoJoinIp;
  const ClientScreen({
    super.key,
    required this.deviceName,
    this.autoJoinIp,
  });

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  final AudioPlayer _player = AudioPlayer();
  final ClockSync _clock = ClockSync();
  final TextEditingController _ipInput = TextEditingController();

  WebSocket? _ws;
  String? _hostIp;
  int _hostPort = kPort;

  bool _searching = false;
  bool _connecting = false;
  bool _connected = false;
  String? _error;
  List<FoundHost> _hosts = [];
  List<String> _myIps = [];

  String _songName = 'Waiting for the host to pick a song...';
  bool _ready = false;
  bool _downloading = false;
  int _percent = 0;
  bool _playing = false;

  double _startAtMs = 0;
  double _startPosSec = 0;
  double _speed = 1.0;

  // A play command that arrived before the song was downloaded / the clock was
  // locked. It is applied as soon as both are ready.
  double? _pendingStartAtMs;
  double? _pendingPosSec;

  Timer? _pll;
  Timer? _keepAlive;
  Timer? _startTimer;
  Future<void> _msgChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _pll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _tick(),
    );

    final auto = widget.autoJoinIp;
    if (auto != null && auto.isNotEmpty) {
      // Deep link: we already know the host, no need to scan the network.
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect(auto));
    } else {
      _search();
    }
  }

  Future<void> _search() async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });

    final ips = await lanIps();
    final hosts = await findHosts(ips);

    if (mounted) {
      setState(() {
        _myIps = ips;
        _hosts = hosts;
        _searching = false;
      });
    }
  }

  Future<void> _connect(String hostIp) async {
    final String ip = cleanHostInput(hostIp);
    if (ip.isEmpty || _connecting) return;

    setState(() {
      _connecting = true;
      _error = null;
      _hostIp = ip;
    });

    // Verify the host is reachable before opening the control channel.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client
          .getUrl(Uri.parse('http://$ip:$_hostPort/ping'))
          .timeout(const Duration(seconds: 4));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      final body = await resp.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['app'] != 'syncwave') {
        throw const FormatException('not a SyncWave host');
      }
      _hostPort = (data['port'] as num?)?.toInt() ?? 8080;
    } catch (e) {
      client.close(force: true);
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = 'Cannot reach $ip ($e). Both phones must be on the same '
              'Wi-Fi, or join the host phone\'s hotspot.';
        });
      }
      return;
    }
    client.close(force: true);

    try {
      final ws = await WebSocket.connect('ws://$ip:$_hostPort/ws')
          .timeout(const Duration(seconds: 6));
      _ws = ws;
      ws.add(jsonEncode({'type': 'hello', 'name': widget.deviceName}));

      ws.listen(
        (data) {
          // Process messages strictly in order: a 'load' and a 'play' must not
          // be handled concurrently.
          _msgChain = _msgChain.then((_) async {
            try {
              await _onMessage(data as String);
            } catch (_) {}
          });
        },
        onDone: _onDisconnected,
        onError: (_) => _onDisconnected(),
      );

      if (mounted) {
        setState(() {
          _connected = true;
          _connecting = false;
        });
      }

      // Initial clock sync burst.
      for (int i = 0; i < 20; i++) {
        if (!_connected) break;
        _ws!.add(jsonEncode({'type': 'ping', 't1': Monotonic.nowMs()}));
        await Future.delayed(const Duration(milliseconds: 30));
      }

      _keepAlive = Timer.periodic(const Duration(seconds: 2), (_) {
        _ws?.add(jsonEncode({'type': 'ping', 't1': Monotonic.nowMs()}));
        _sendStatus();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connected = false;
          _error = 'Connected to $ip but the audio channel failed: $e';
        });
      }
    }
  }

  Future<void> _onMessage(String raw) async {
    final t4 = Monotonic.nowMs();
    final msg = jsonDecode(raw) as Map<String, dynamic>;

    switch (msg['type']) {
      case 'pong':
        _clock.addSample(
          (msg['t1'] as num).toDouble(),
          (msg['t2'] as num).toDouble(),
          (msg['t3'] as num).toDouble(),
          t4,
        );
        break;

      case 'load':
        final trackId = (msg['trackId'] as String?) ?? '';
        final title = (msg['title'] as String?) ?? 'Shared song';
        await _downloadSong(trackId, title);
        break;

      case 'play':
        await _startPlayback(
          (msg['startAtMs'] as num).toDouble(),
          (msg['startPosSec'] as num).toDouble(),
        );
        break;

      case 'pause':
        _startTimer?.cancel();
        _pendingStartAtMs = null;
        _pendingPosSec = null;
        final pos = (msg['posSec'] as num).toDouble();
        if (mounted) setState(() => _playing = false);
        await _player.pause();
        await _player.seek(Duration(milliseconds: (pos * 1000).round()));
        break;
    }
  }

  void _onDisconnected() {
    _keepAlive?.cancel();
    _startTimer?.cancel();
    _pendingStartAtMs = null;
    _pendingPosSec = null;
    _player.stop();
    if (mounted) {
      setState(() {
        _connected = false;
        _ready = false;
        _playing = false;
      });
    }
  }

  void _sendStatus() {
    _ws?.add(jsonEncode({
      'type': 'status',
      'ready': _ready,
      'progress': _percent,
    }));
  }

  Future<void> _downloadSong(String trackId, String title) async {
    final String ip = _hostIp ?? '';
    if (ip.isEmpty) return;

    _startTimer?.cancel();
    await _player.stop();
    if (mounted) {
      setState(() {
        _songName = title;
        _ready = false;
        _downloading = true;
        _percent = 0;
        _playing = false;
      });
    }
    _sendStatus();

    try {
      final client = HttpClient();
      final req = await client
          .getUrl(Uri.parse('http://$ip:$_hostPort/track.mp3?id=$trackId'))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 60));

      final int total = resp.contentLength;
      final builder = BytesBuilder(copy: false);
      int received = 0;

      await for (final chunk in resp) {
        builder.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final int pct = (received * 100 ~/ total).clamp(0, 99);
          if (pct != _percent && mounted) {
            setState(() => _percent = pct);
            _sendStatus();
          }
        }
      }

      final bytes = builder.takeBytes();
      await _player.setAudioSource(
        RamSource(bytes, contentType: audioContentType(title)),
      );

      if (mounted) {
        setState(() {
          _downloading = false;
          _ready = true;
          _percent = 100;
        });
      }
      _sendStatus();
    } catch (_) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _ready = false;
        });
      }
    }
  }

  Future<void> _startPlayback(double startAtMs, double startPosSec) async {
    if (!_ready || !_clock.locked) {
      // Song still downloading or the clock is not synchronised yet: remember the
      // command and run it as soon as both are ready.
      _pendingStartAtMs = startAtMs;
      _pendingPosSec = startPosSec;
      return;
    }
    _startTimer?.cancel();

    if (mounted) {
      setState(() {
        _playing = true;
        _startAtMs = startAtMs;
        _startPosSec = startPosSec;
      });
    }

    await _player.pause();
    await _player.setSpeed(1.0);
    _speed = 1.0;

    final double wait = startAtMs - _clock.hostNowMs();
    if (wait > 0) {
      await _player.seek(
        Duration(milliseconds: (startPosSec * 1000).round()),
      );
      _startTimer = Timer(
        Duration(microseconds: (wait * 1000).round()),
        () => _player.play(),
      );
    } else {
      final double catchUp = startPosSec - wait / 1000.0;
      await _player.seek(
        Duration(milliseconds: (catchUp * 1000).round()),
      );
      _player.play();
    }
  }

  void _keepInSync() {
    if (!_playing || !_player.playing || !_ready) return;
    final double elapsed = (_clock.hostNowMs() - _startAtMs) / 1000.0;
    if (elapsed < 0.3) return;

    final double expected = (_startPosSec + elapsed) * 1000.0;
    final double actual = _player.position.inMilliseconds.toDouble();
    final double error = expected - actual;

    if (Pll.needsHardSeek(error)) {
      _player.seek(Duration(milliseconds: expected.round()));
      if (_speed != 1.0) {
        _speed = 1.0;
        _player.setSpeed(1.0);
      }
      return;
    }

    final double target = Pll.speedFor(error);
    if ((target - _speed).abs() > 0.0005) {
      _speed = target;
      _player.setSpeed(target);
    }
  }

  /// Runs every 250 ms: applies a play command that arrived before the song was
  /// ready, then keeps the playback locked to the host clock.
  void _tick() {
    if (_pendingStartAtMs != null) {
      if (!_ready || !_clock.locked) return;
      final double at = _pendingStartAtMs!;
      final double pos = _pendingPosSec!;
      _pendingStartAtMs = null;
      _pendingPosSec = null;
      _startPlayback(at, pos);
      return;
    }
    _keepInSync();
  }

  @override
  void dispose() {
    _pll?.cancel();
    _keepAlive?.cancel();
    _startTimer?.cancel();
    _ws?.close();
    _ipInput.dispose();
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
      ),
      body: SafeArea(child: _connected ? _speakerView() : _joinView()),
    );
  }

  Widget _joinView() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF151926),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              if (_searching)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.wifi_find_rounded, color: Colors.white54),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _searching
                      ? 'Searching the Wi-Fi for a party...'
                      : _hosts.isEmpty
                          ? 'No party found. Make sure the host phone is on the same Wi-Fi '
                              '(or that you joined its hotspot), then search again.'
                          : 'Found ${_hosts.length} party. Tap to join.',
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        ..._hosts.map(
          (h) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              height: 54,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _connecting ? null : () => _connect(h.ip),
                icon: const Icon(Icons.wifi_tethering_rounded),
                label: Text(
                  'Join ${h.name}  (${h.ip})',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _searching ? null : _search,
          icon: const Icon(Icons.radar_rounded),
          label: const Text('Search Again'),
        ),

        const SizedBox(height: 22),
        const Text(
          'Or type the Host IP',
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ipInput,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  hintText: '192.168.1.5',
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
                onSubmitted: _connect,
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
                onPressed: _connecting ? null : () => _connect(_ipInput.text),
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

        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x33EF4444),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5)),
            ),
          ),
        ],

        if (_myIps.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            'Your IP: ${_myIps.join(", ")}',
            style: const TextStyle(fontSize: 11, color: Colors.white30),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Widget _speakerView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF151926),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _playing ? Icons.graphic_eq_rounded : Icons.headphones_rounded,
                size: 64,
                color: _playing
                    ? const Color(0xFF34D399)
                    : const Color(0xFF818CF8),
              ),
              const SizedBox(height: 16),
              Text(
                _songName,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              if (_downloading) ...[
                LinearProgressIndicator(
                  value: _percent / 100,
                  backgroundColor: Colors.white12,
                  color: const Color(0xFF6366F1),
                ),
                const SizedBox(height: 10),
                Text('Loading song... $_percent%'),
              ] else
                Text(
                  _playing
                      ? 'Playing in sync'
                      : _ready
                          ? 'Ready — waiting for the host'
                          : 'Connected — waiting for the host',
                  style: const TextStyle(color: Color(0xFF34D399)),
                ),
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: _onDisconnected,
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
