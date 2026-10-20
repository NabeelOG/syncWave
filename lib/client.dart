import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'device_audio.dart';
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
  final PositionTracker _position = PositionTracker();
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

  // Timestamp of the last hard seek, used to rate-limit audible corrections.
  double _lastSeekAtMs = 0;

  // Last measured phase error against the host (ms), shown in the UI.
  double _lastErrorMs = 0;

  // Deadline until which the drift correction uses the stronger gain.
  double _aggressiveUntilMs = 0;

  // Rate error estimate (ms of phase drift per ms of time) and the time of the
  // previous measurement, used to derive it.
  double _rateEstimate = 0;
  double _lastErrorAtMs = 0;
  double _prevErrorMs = 0;

  /// How much earlier this phone must start than the host so that the sound
  /// leaves both speakers at the same moment:
  ///   (my output latency - host output latency) + manual nudge
  /// Positive = this phone starts earlier.
  double _latencyOffsetMs = 0;
  double _myLatencyMs = 0;
  double _hostLatencyMs = 0;
  int _nudgeMs = 0;

  Timer? _pll;
  Timer? _keepAlive;
  Timer? _startTimer;
  Timer? _searchTimer;
  Timer? _syncCheckTimer;
  StreamSubscription<Duration>? _posSub;
  Future<void> _msgChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();

    // Track the playhead on the monotonic clock: the player's own position
    // interpolation uses the wall clock, which Android adjusts over time.
    _posSub = _player.positionStream.listen((p) {
      _position.sync(p.inMilliseconds.toDouble());
    });

    _loadDeviceAudio();
    _pll = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _tick(),
    );
    _syncCheckTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _syncCheck(),
    );

    final auto = widget.autoJoinIp;
    if (auto != null && auto.isNotEmpty) {
      // Deep link: we already know the host, no need to scan the network.
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect(auto));
    } else {
      _search(thorough: true);
      // Keep looking: the host may start later, or the Wi-Fi may still have
      // been associating when the first sweep ran.
      _searchTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) {
          if (!_connected) _search();
        },
      );
    }
  }

  /// Reads this phone's output latency and the saved manual nudge.
  Future<void> _loadDeviceAudio() async {
    _myLatencyMs = await DeviceAudio.outputLatencyMs();
    _nudgeMs = await DeviceAudio.nudgeMs();
    if (mounted) {
      setState(() => _recomputeLatencyOffset());
    }
  }

  void _recomputeLatencyOffset() {
    _latencyOffsetMs = (_myLatencyMs - _hostLatencyMs) + _nudgeMs.toDouble();
  }

  /// Scans the network for a host.
  /// [thorough] runs a second pass - the first attempt on an address usually
  /// fails because the ARP entry is not cached yet.
  Future<void> _search({bool thorough = false}) async {
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = null;
    });

    // Read the local addresses again every time: the Wi-Fi may have just been
    // associated, in which case the first sweep had nothing to work with.
    final ips = await lanIps();
    final hosts = await findHosts(ips, rounds: thorough ? 2 : 1);

    if (mounted) {
      setState(() {
        _myIps = ips;
        if (hosts.isNotEmpty) _hosts = hosts;
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
      _hostLatencyMs = (data['latencyMs'] as num?)?.toDouble() ?? 0.0;
      _recomputeLatencyOffset();
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

      case 'ping2':
        // The host is measuring this phone's clock in the other direction.
        // Answer with our receive/send timestamps so it can cancel the
        // asymmetric delay of the uplink.
        _ws?.add(jsonEncode({
          'type': 'pong2',
          't1h': msg['t1h'],
          't2c': t4,
          't3c': Monotonic.nowMs(),
        }));
        break;

      case 'clock':
        // The host's own estimate of the clock offset.
        _clock.setReverse(
          (msg['deltaMs'] as num).toDouble(),
          (msg['rttMs'] as num).toDouble(),
        );
        break;

      case 'load':
        final trackId = (msg['trackId'] as String?) ?? '';
        final title = (msg['title'] as String?) ?? 'Shared song';
        await _downloadSong(trackId, title);
        break;

      case 'play':
        if (msg['latencyMs'] != null) {
          _hostLatencyMs = (msg['latencyMs'] as num).toDouble();
          _recomputeLatencyOffset();
        }
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
      'errorMs': _lastErrorMs,
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

      // Pre-roll: park the decoder at position 0 and wait until the player is
      // ready, so the "play" command does not have to seek (and does not start
      // this phone late).
      await _player.seek(Duration.zero);
      _position.reset(0);
      await _player.processingStateStream
          .firstWhere((s) => s == ProcessingState.ready)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => _player.processingState,
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

    // Only seek when the player is not already at the right place. A seek on an
    // MP3 costs 100-500 ms, and that cost must not delay the start: every phone
    // would otherwise start a different amount late.
    final int targetMs = (startPosSec * 1000).round();
    final int currentMs = _position.positionMs.round();
    if ((currentMs - targetMs).abs() > 30) {
      await _player.seek(Duration(milliseconds: targetMs));
    }
    _position.reset(targetMs.toDouble());

    // Compute the remaining time AFTER the seek so its cost is absorbed here
    // instead of shifting this phone's start away from the shared timeline.
    // This phone starts _latencyOffsetMs earlier so that the sound leaves both
    // speakers at the same moment (the host's speaker path is slower/faster).
    final double wait =
        (startAtMs - _latencyOffsetMs) - _clock.hostNowMs();
    if (wait > 0) {
      _startTimer = Timer(
        Duration(microseconds: (wait * 1000).round()),
        () => _player.play(),
      );
    } else {
      // Already late: jump straight to where the room currently is, so the
      // content matches even though the start instant was missed.
      final int posMs = targetMs + (-wait).round();
      if ((_position.positionMs.round() - posMs).abs() > 30) {
        await _player.seek(Duration(milliseconds: posMs));
      }
      _position.reset(posMs.toDouble());
      _player.play();
    }
  }

  void _keepInSync() {
    if (!_playing || !_player.playing || !_ready) return;
    final double elapsed = (_clock.hostNowMs() - _startAtMs) / 1000.0;
    if (elapsed < 0.5) return;

    final double expected =
        (_startPosSec + elapsed) * 1000.0 + _latencyOffsetMs;
    final double actual = _position.positionMs;
    final double error = expected - actual;

    _updateRate(error);

    if (mounted && (error - _lastErrorMs).abs() > 1.0) {
      setState(() => _lastErrorMs = error);
    }

    // A hard seek is audible, so it is only used for a real desync and never
    // twice in a row (the constant offset between two phones must not trigger
    // it, otherwise the audio turns into chopping).
    if (Pll.needsHardSeek(error)) {
      final double now = Monotonic.nowMs();
      if (now - _lastSeekAtMs > 2000) {
        _lastSeekAtMs = now;
        _player.seek(Duration(milliseconds: expected.round()));
        _position.reset(expected);
        if (_speed != 1.0) {
          _speed = 1.0;
          _position.setSpeed(1.0);
          _player.setSpeed(1.0);
        }
      }
      return;
    }

    // Smooth rate trim: no clicks, no audible pitch change.
    // After a periodic check flagged a drift, pull in harder for a few seconds.
    final bool aggressive = Monotonic.nowMs() < _aggressiveUntilMs;
    _applyTrim(error, aggressive: aggressive);
  }

  /// Estimates how fast the phase error is growing (ms of drift per ms of
  /// time). This is the difference between the two phones' crystal clocks and
  /// is what the integral term of the controller cancels.
  void _updateRate(double error) {
    final double now = Monotonic.nowMs();
    if (_lastErrorAtMs > 0) {
      final double dt = now - _lastErrorAtMs;
      if (dt > 1000) {
        final double d = (error - _prevErrorMs) / dt;
        _rateEstimate = _rateEstimate * 0.7 + d * 0.3;
      }
    }
    _prevErrorMs = error;
    _lastErrorAtMs = now;
  }

  /// Periodic (5 s) sync check. If this phone has drifted noticeably out of
  /// phase it pulls in harder than the continuous loop so it locks on within
  /// a couple of seconds instead of slowly creeping back.
  void _syncCheck() {
    if (!_playing || !_player.playing || !_ready) return;
    final double elapsed = (_clock.hostNowMs() - _startAtMs) / 1000.0;
    if (elapsed < 0.5) return;

    final double expected =
        (_startPosSec + elapsed) * 1000.0 + _latencyOffsetMs;
    final double actual = _position.positionMs;
    final double error = expected - actual;

    if (Pll.needsHardSeek(error)) {
      final double now = Monotonic.nowMs();
      if (now - _lastSeekAtMs > 2000) {
        _lastSeekAtMs = now;
        _player.seek(Duration(milliseconds: expected.round()));
        _position.reset(expected);
        if (_speed != 1.0) {
          _speed = 1.0;
          _position.setSpeed(1.0);
          _player.setSpeed(1.0);
        }
      }
      return;
    }

    if (error.abs() > Pll.deadbandMs * 2) {
      // Pull in harder for the next few seconds so the phone locks on quickly.
      _aggressiveUntilMs = Monotonic.nowMs() + 4000;
      _applyTrim(error, aggressive: true);
    }
  }

  void _applyTrim(double error, {required bool aggressive}) {
    final double target = Pll.speedFor(
      error,
      rateError: _rateEstimate,
      aggressive: aggressive,
    );
    if ((target - _speed).abs() > 0.0002) {
      _speed = target;
      _position.setSpeed(target);
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
    _searchTimer?.cancel();
    _syncCheckTimer?.cancel();
    _posSub?.cancel();
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
          onPressed: _searching ? null : () => _search(thorough: true),
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

  /// Shows how far this phone currently is from the host.
  Widget _syncBadge() {
    final double err = _lastErrorMs;
    final bool locked = err.abs() <= Pll.deadbandMs;
    final Color color = locked
        ? const Color(0xFF34D399)
        : err.abs() <= 25
            ? const Color(0xFFFBBF24)
            : const Color(0xFFF87171);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        locked
            ? 'LOCKED  ±${err.abs().toStringAsFixed(1)} ms'
            : 'SYNCING  ${err >= 0 ? "+" : ""}${err.toStringAsFixed(0)} ms',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  /// Fine tuning control: shifts this phone relative to the host.
  /// Positive values make this phone play earlier.
  Widget _nudgeControl() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.tune_rounded, size: 16, color: Colors.white38),
            const SizedBox(width: 6),
            const Text(
              'Sync nudge',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(width: 8),
            Text(
              '${_nudgeMs > 0 ? '+' : ''}$_nudgeMs ms',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF818CF8),
              ),
            ),
          ],
        ),
        Slider(
          value: _nudgeMs.toDouble(),
          min: -60,
          max: 60,
          divisions: 24,
          label: '$_nudgeMs ms',
          onChanged: (v) => setState(() => _nudgeMs = v.round()),
          onChangeEnd: (v) async {
            await DeviceAudio.setNudgeMs(v.round());
            _recomputeLatencyOffset();
          },
        ),
        const Text(
          'Positive = this phone plays earlier. Adjust by ear until the two '
          'phones sound like one.',
          style: TextStyle(fontSize: 10, color: Colors.white30),
          textAlign: TextAlign.center,
        ),
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
                Column(
                  children: [
                    Text(
                      _playing
                          ? 'Playing in sync'
                          : _ready
                              ? 'Ready — waiting for the host'
                              : 'Connected — waiting for the host',
                      style: const TextStyle(color: Color(0xFF34D399)),
                    ),
                    if (_playing) ...[
                      const SizedBox(height: 6),
                      _syncBadge(),
                    ],
                  ],
                ),
              const SizedBox(height: 24),
              _nudgeControl(),
              const SizedBox(height: 8),
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
