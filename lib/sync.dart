import 'dart:io';
import 'dart:math';

/// Shown in the UI so it is obvious when two phones run different builds.
const String kAppVersion = '3.0.0';

/// Monotonic clock (microsecond resolution, immune to wall-clock changes).
class Monotonic {
  static final Stopwatch _sw = Stopwatch()..start();
  static double nowMs() => _sw.elapsedMicroseconds / 1000.0;
}

/// Tracks the playback position on a monotonic clock.
///
/// `AudioPlayer.position` interpolates using `DateTime.now()` (the wall
/// clock), so a system clock adjustment - which Android performs regularly via
/// NTP - makes the reported position jump by tens of milliseconds. Measuring
/// against that value would make the drift controller react to a phantom
/// error, so the position is anchored here on the monotonic clock instead.
class PositionTracker {
  double _posMs = 0;
  double _localMs;
  double _speed = 1.0;

  PositionTracker() : _localMs = Monotonic.nowMs();

  /// Current position in milliseconds, extrapolated on the monotonic clock.
  double get positionMs =>
      _posMs + (Monotonic.nowMs() - _localMs) * _speed;

  double get speed => _speed;

  /// Re-anchors to an authoritative position value (e.g. from the player).
  void sync(double reportedPosMs) {
    _posMs = reportedPosMs;
    _localMs = Monotonic.nowMs();
  }

  /// Re-anchors to an explicit position, e.g. after a seek.
  void reset(double posMs) => sync(posMs);

  /// Keeps the extrapolation exact when the playback rate changes.
  void setSpeed(double speed) {
    _posMs = positionMs;
    _localMs = Monotonic.nowMs();
    _speed = speed;
  }
}

/// Keeps the samples of one clock-sync direction and extracts a robust offset.
///
/// Only the samples that suffered the least delay are used: Wi-Fi queues
/// packets unpredictably, so a delayed sample carries an asymmetric delay and
/// biases the offset. The median of the fastest samples is used instead of
/// their mean so that a single odd sample cannot pull the estimate.
class OffsetEstimator {
  final List<({double rtt, double offset})> _samples = [];
  double _minRtt = 1e9;

  bool get hasSamples => _samples.isNotEmpty;
  double get minRttMs => _minRtt;

  void add(double rtt, double offset) {
    if (rtt < 0 || rtt > 1000) return;
    _samples.add((rtt: rtt, offset: offset));
    if (_samples.length > 30) _samples.removeAt(0);
    _minRtt = _samples.map((s) => s.rtt).reduce(min);
  }

  /// Median offset of the samples that were delayed the least.
  double get offsetMs {
    if (_samples.isEmpty) return 0;
    final band = _samples
        .where((s) => s.rtt <= _minRtt * 1.15 + 0.5)
        .map((s) => s.offset)
        .toList()
      ..sort();
    return band[band.length ~/ 2];
  }

  void reset() {
    _samples.clear();
    _minRtt = 1e9;
  }
}

/// NTP-style clock sync over the WebSocket control channel.
///
/// The Host timestamps (t2 = receive, t3 = send) are used to estimate the
/// offset between this device's monotonic clock and the Host's clock:
///
///     rtt    = (t4 - t1) - (t3 - t2)
///     offset = ((t2 - t1) + (t3 - t4)) / 2
///
/// The offset is measured with a burst at connect and then *held*. It is
/// deliberately not updated afterwards: a clock offset that moves while the
/// playback loop is trying to track it makes the loop chase a moving target,
/// which shows up as the audio drifting in and out of sync. A constant offset
/// of a millisecond or two is harmless - the playback loop corrects for it.
class ClockSync {
  final OffsetEstimator _own = OffsetEstimator();

  double get offsetMs => _own.offsetMs;
  double get minRttMs => _own.minRttMs;
  bool get locked => _own.hasSamples;

  /// Current time expressed on the Host's clock.
  double hostNowMs() => Monotonic.nowMs() + _own.offsetMs;

  void reset() => _own.reset();

  /// A sample measured by this device pinging the Host.
  void addSample(double t1, double t2, double t3, double t4) {
    final rtt = (t4 - t1) - (t3 - t2);
    final offset = ((t2 - t1) + (t3 - t4)) / 2.0;
    _own.add(rtt, offset);
  }
}
}

/// Drift correction.
///
/// Two phones never start at exactly the same moment: each phone has its own
/// audio pipeline start-up delay (20-100 ms) and its own output latency. That
/// offset is constant and cannot be removed by seeking - seeking only shifts
/// the content and leaves the pipeline delay in place, so a hard seek would
/// just repeat forever and sound like chopping.
///
/// The constant part is handled up front (see DeviceAudio / the latency
/// offset), so what is left here is real drift, corrected with a PI
/// controller:
///
///   phase term  - pulls the playhead onto the host's timeline
///   rate term   - cancels the difference between the two crystal clocks
///                 (100 ppm would be 24 ms over four minutes)
///
/// The controller has two parts that act on different things:
///
///   phase term  - a proportional correction of the *position* error. A
///                 proportional loop on a position plant is a stable
///                 first-order system, so it cannot ring.
///
///   rate term   - a feedforward of the *speed*. The difference between two
///                 phones' crystal clocks (100 ppm = 24 ms over four minutes)
///                 is a rate error, and it is measured directly: the Host
///                 publishes its playhead, the client sees how far it advanced
///                 in the same window and trims its base speed so that both
///                 advance at exactly the same rate. A feedforward is not a
///                 feedback loop, so it cannot fight the phase term.
///
///   |error| <= deadband -> no phase term
///   > 300 ms            -> hard re-seek (stall, late join, ...)
class Pll {
  /// Phase errors below this are measurement noise, so no correction is made.
  static const double deadbandMs = 2.0;
  static const double hardSeekMs = 300.0;

  static const double maxTrim = 0.015; // 1.5% -> ~26 cents, barely audible
  static const double gain = 0.0006; // per ms of phase error

  /// Maximum speed change per control tick. Keeps the playback from stepping
  /// (a step sounds like a click) while still converging in about a second.
  static const double maxSpeedStep = 0.0015; // 0.15%

  /// Proportional correction for the given phase error (expected - actual, ms).
  static double phaseTrim(double errorMs) {
    if (errorMs.abs() <= deadbandMs) return 0.0;
    return (gain * errorMs).clamp(-maxTrim, maxTrim);
  }

  static bool needsHardSeek(double errorMs) => errorMs.abs() > hardSeekMs;
}

/// This device's LAN IPv4 addresses (Wi-Fi or hotspot), most useful first.
Future<List<String>> lanIps() async {
  final wifi = <String>[];
  final other = <String>[];

  try {
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in ifaces) {
      final name = iface.name.toLowerCase();
      // Skip cellular data, VPN and virtual tunnels.
      if (name.contains('rmnet') ||
          name.contains('ccmni') ||
          name.contains('pdp') ||
          name.contains('clat') ||
          name.contains('tun') ||
          name.contains('tap') ||
          name.contains('dummy')) {
        continue;
      }
      final isLan = name.contains('wlan') ||
          name.contains('wifi') ||
          name.contains('ap') ||
          name.contains('swlan') ||
          name.contains('eth') ||
          name.contains('rndis');
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (addr.isLoopback || ip.startsWith('169.254.')) continue;
        (isLan ? wifi : other).add(ip);
      }
    }
  } catch (_) {}

  return [...wifi, ...other];
}
