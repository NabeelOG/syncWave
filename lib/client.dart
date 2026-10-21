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

  // Integral term of the drift controller and the sign of the previous error
  // (used to tell a real drift apart from measurement noise).
  double _filteredErrorMs = 0;

  // Rate matching: the base speed is trimmed so that this phone advances at
  // exactly the same rate as the host's playhead.
  double _baseSpeed = 1.0;
  double _hostRate = 1.0;
  double _rateHostDelta = 0;
  double _rateClientDelta = 0;
  double _rateClockDelta = 0;

  // The host's last published playhead and the clock time it was taken at.
  double _hostAnchorPosMs = 0;
  double _hostAnchorAtMs = 0;
  double _hostAnchorClientPos = 0;

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
      ws.add(jsonEncode({
        'type': 'hello',
        'name': widget.deviceName,
        'version': kAppVersion,
      }));

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

      case 'sync':
        // The host published its actual playhead.
        _onHostSync(
          (msg['posMs'] as num).toDouble(),
          (msg['atMs'] as num).toDouble(),
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
    _resetController();

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
    if (_hostAnchorAtMs <= 0) return; // no playhead received from the host yet

    // The reference is the host's *actual* playhead, not the schedule. The two
    // phones then follow the same audio instead of pulling against each other.
    final double expected = _hostExpectedPosMs() + _latencyOffsetMs;
    final double error = expected - _position.positionMs;

    // The position measurement carries a couple of milliseconds of jitter, so
    // the controller works on a lightly filtered error. A slow drift is not
    // affected by the filter.
    _filteredErrorMs = _filteredErrorMs * 0.7 + error * 0.3;

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
        _resetController();
        if (_speed != 1.0) {
          _speed = 1.0;
          _position.setSpeed(1.0);
          _player.setSpeed(1.0);
        }
      }
      return;
    }

    // Proportional phase correction (a stable first order loop) on top of the
    // rate matched base speed (a feedforward).
    final bool aggressive = Monotonic.nowMs() < _aggressiveUntilMs;
    _applySpeed(
      _baseSpeed + Pll.phaseTrim(_filteredErrorMs, aggressive: aggressive),
    );
  }

  /// Where the host's playhead is right now, extrapolated from the last
  /// position the host published.
  double _hostExpectedPosMs() {
    final double dt = _clock.hostNowMs() - _hostAnchorAtMs;
    return _hostAnchorPosMs + dt * _hostRate;
  }

  /// The host published its playhead: remember it and use the window to
  /// measure whether this phone advances at the same rate.
  void _onHostSync(double hostPosMs, double hostAtMs) {
    final double clientPos = _position.positionMs;

    final double clockDelta = hostAtMs - _hostAnchorAtMs;
    final double hostDelta = hostPosMs - _hostAnchorPosMs;
    final double clientDelta = clientPos - _hostAnchorClientPos;

    if (clockDelta > 0) {
      // The host's content rate relative to its own clock.
      _hostRate = _hostRate * 0.8 + (hostDelta / clockDelta) * 0.2;
    }

    // Accumulate a longer window before trimming the base speed: measuring the
    // rate over 500 ms is too noisy, over a few seconds it is clean.
    _rateHostDelta += hostDelta;
    _rateClientDelta += clientDelta;
    _rateClockDelta += clockDelta;

    if (_rateClockDelta >= 3000 && _rateHostDelta > 500) {
      final double hostRate = _rateHostDelta / _rateClockDelta;
      final double clientRate = _rateClientDelta / _rateClockDelta;
      // Trim the base speed so both phones advance at the same rate. This is a
      // feedforward, so it cannot fight the phase correction.
      _baseSpeed =
          (_baseSpeed - (clientRate - hostRate) * 0.3).clamp(0.97, 1.03);
      _rateHostDelta = 0;
      _rateClientDelta = 0;
      _rateClockDelta = 0;
    }

    // Move our reference towards the host's playhead instead of snapping to
    // it: a snapped reference would jump the phase error on every message.
    final double measuredNow =
        hostPosMs + (_clock.hostNowMs() - hostAtMs) * _hostRate;

    if (_hostAnchorAtMs <= 0) {
      _hostAnchorPosMs = measuredNow;
      _hostAnchorAtMs = _clock.hostNowMs();
    } else {
      final double current = _hostExpectedPosMs();
      final double diff = measuredNow - current;
      // While playing, correct at most 10 ms per message (20 ms/s). Before
      // playback starts there is nothing to hear, so snap immediately.
      final double step = _playing ? 10.0 : 100000.0;
      _hostAnchorPosMs = current + diff.clamp(-step, step);
      _hostAnchorAtMs = _clock.hostNowMs();
    }

    _hostAnchorClientPos = clientPos;
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

  /// Clears the controller state (after a seek or a new start).
  void _resetController() {
    _baseSpeed = 1.0;
    _filteredErrorMs = 0;
    _hostAnchorAtMs = 0;
    _hostAnchorPosMs = 0;
    _hostAnchorClientPos = 0;
    _hostRate = 1.0;
    _rateHostDelta = 0;
    _rateClientDelta = 0;
    _rateClockDelta = 0;
  }

  /// Periodic (5 s) sync check. If this phone has drifted noticeably out of
  /// phase it pulls in harder than the continuous loop so it locks on within
  /// a couple of seconds instead of slowly creeping back.
  void _syncCheck() {
    if (!_playing || !_player.playing || !_ready) return;
    if (_hostAnchorAtMs <= 0) return;

    final double expected = _hostExpectedPosMs() + _latencyOffsetMs;
    final double error = expected - _position.positionMs;

    if (Pll.needsHardSeek(error)) {
      final double now = Monotonic.nowMs();
      if (now - _lastSeekAtMs > 2000) {
        _lastSeekAtMs = now;
        _player.seek(Duration(milliseconds: expected.round()));
        _position.reset(expected);
        _resetController();
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
      _applySpeed(
        _baseSpeed + Pll.phaseTrim(_filteredErrorMs, aggressive: true),
      );
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

  /// Small readout of the values the sync loop is built on, so a jumping
  /// component is visible instead of guessed.
  Widget _diagnostics() {
    final String rtt = _clock.locked && _clock.minRttMs < 9000
        ? '${_clock.minRttMs.toStringAsFixed(0)}ms'
        : '--';
    return Text(
      'clk ${_clock.offsetMs.toStringAsFixed(1)}ms  ·  rtt $rtt  ·  '
      'rate ${_hostRate.toStringAsFixed(4)}  ·  v$kAppVersion',
      style: const TextStyle(
        fontSize: 10,
        color: Colors.white30,
        fontFamily: 'monospace',
      ),
      textAlign: TextAlign.center,
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
                      const SizedBox(height: 6),
                      _diagnostics(),
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
