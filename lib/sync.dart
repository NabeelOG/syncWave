import 'dart:io';
import 'dart:math';

/// Monotonic clock (microsecond resolution, immune to wall-clock changes).
class Monotonic {
  static final Stopwatch _sw = Stopwatch()..start();
  static double nowMs() => _sw.elapsedMicroseconds / 1000.0;
}

/// NTP-style clock sync over the WebSocket control channel.
///
/// Host timestamps (t2 = receive, t3 = send) are used to estimate the offset
/// between this device's monotonic clock and the Host's clock.
///
///     rtt    = (t4 - t1) - (t3 - t2)
///     offset = ((t2 - t1) + (t3 - t4)) / 2
///
/// Wi-Fi queues packets unpredictably, so only the fastest 40% of samples are
/// averaged (the ones that suffered the least router delay).
class ClockSync {
  final List<({double rtt, double offset})> _samples = [];
  double _offsetMs = 0;
  double _minRttMs = 9999;
  bool _locked = false;

  double get offsetMs => _offsetMs;
  double get minRttMs => _minRttMs;
  bool get locked => _locked;

  void reset() {
    _samples.clear();
    _offsetMs = 0;
    _minRttMs = 9999;
    _locked = false;
  }

  void addSample(double t1, double t2, double t3, double t4) {
    final rtt = (t4 - t1) - (t3 - t2);
    final offset = ((t2 - t1) + (t3 - t4)) / 2.0;
    if (rtt < 0 || rtt > 1000) return;

    _samples.add((rtt: rtt, offset: offset));
    if (_samples.length > 30) _samples.removeAt(0);

    final sorted = List<({double rtt, double offset})>.from(_samples)
      ..sort((a, b) => a.rtt.compareTo(b.rtt));
    _minRttMs = sorted.first.rtt;

    final keep = max(1, (sorted.length * 0.4).ceil());
    final best = sorted.take(keep);
    final mean = best.fold<double>(0, (s, x) => s + x.offset) / keep;

    if (!_locked) {
      _offsetMs = mean;
    } else if (rtt <= _minRttMs * 1.35 + 1.5) {
      _offsetMs = _offsetMs * 0.75 + mean * 0.25;
    }
    if (_samples.length >= 4) _locked = true;
  }

  /// Current time expressed on the Host's clock.
  double hostNowMs() => Monotonic.nowMs() + _offsetMs;
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
/// offset), so all that is left here is real drift:
///
///   |error| <= 5 ms   -> locked, play at exactly 1.000x
///   5..300 ms         -> proportional speed trim of at most +/-1.5%
///   > 300 ms          -> hard re-seek (stall, late join, ...)
class Pll {
  static const double deadbandMs = 5.0;
  static const double hardSeekMs = 300.0;
  static const double maxTrim = 0.015; // 1.5% -> ~26 cents, barely audible

  /// Speed to apply for the given phase error (expected - actual, ms).
  static double speedFor(double errorMs) {
    if (errorMs.abs() <= deadbandMs) return 1.0;
    final double trim = (0.0012 * errorMs).clamp(-maxTrim, maxTrim);
    return 1.0 + trim;
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
