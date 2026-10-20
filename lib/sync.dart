import 'dart:io';
import 'dart:math';

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
/// The estimate is biased by half the difference between the upstream and
/// downstream delay, and that bias grows with the delay. To get rid of it the
/// sync runs in *both* directions: the Host also pings this device and shares
/// its own view of the offset. Whichever direction had the lower delay is the
/// more trustworthy one and is used.
class ClockSync {
  final OffsetEstimator _own = OffsetEstimator();

  // The Host's view of the same offset, measured in the opposite direction.
  double? _reverseDeltaMs;
  double _reverseRttMs = 1e9;

  double get offsetMs {
    final own = _own.offsetMs;
    if (_reverseDeltaMs != null && _reverseRttMs < _own.minRttMs) {
      return _reverseDeltaMs!;
    }
    return own;
  }

  double get minRttMs {
    if (_reverseDeltaMs != null && _reverseRttMs < _own.minRttMs) {
      return _reverseRttMs;
    }
    return _own.minRttMs;
  }

  bool get locked => _own.hasSamples || _reverseDeltaMs != null;

  void reset() {
    _own.reset();
    _reverseDeltaMs = null;
    _reverseRttMs = 1e9;
  }

  /// A sample measured by this device pinging the Host.
  void addSample(double t1, double t2, double t3, double t4) {
    final rtt = (t4 - t1) - (t3 - t2);
    final offset = ((t2 - t1) + (t3 - t4)) / 2.0;
    _own.add(rtt, offset);
  }

  /// The Host's estimate of the same offset, measured in the other direction.
  void setReverse(double deltaMs, double rttMs) {
    if (rttMs < 0 || rttMs > 1000) return;
    _reverseDeltaMs = deltaMs;
    _reverseRttMs = rttMs;
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
///   |error| <= deadband -> locked, play at exactly 1.000x
///   > 300 ms            -> hard re-seek (stall, late join, ...)
class Pll {
  static const double deadbandMs = 5.0;
  static const double hardSeekMs = 300.0;

  static const double maxTrim = 0.015; // 1.5% -> ~26 cents, barely audible
  static const double maxRateTrim = 0.004; // 0.4%
  static const double gain = 0.0006; // per ms of phase error
  static const double rateGain = 0.8; // per ms/ms of rate error

  /// Speed for the given phase error (expected - actual, ms) and rate error
  /// (ms of phase drift per ms of time).
  static double speedFor(
    double errorMs, {
    double rateError = 0.0,
    bool aggressive = false,
  }) {
    if (errorMs.abs() <= deadbandMs) return 1.0;
    final double g = aggressive ? gain * 2.5 : gain;
    final double cap = aggressive ? 0.03 : maxTrim;
    final double phase = (g * errorMs).clamp(-cap, cap);
    final double rate =
        (rateGain * rateError).clamp(-maxRateTrim, maxRateTrim);
    return 1.0 + phase + rate;
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
