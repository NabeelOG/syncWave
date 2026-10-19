# SyncWave: Multi-Phone Synchronized Wi-Fi Audio Architecture

## 1. Selected Tech Stack (Dual-Mode Architecture)

To give you both an **immediately testable multi-phone experience right now** and a **native standalone mobile codebase**, this repository implements a dual-stack architecture using the exact same synchronization math:

1. **Zero-Install Mobile PWA + Go High-Precision LAN Host (`main.go` + `web/`)**
   - **Why:** Guests don't need to install an app from the App Store / Play Store. Any phone on the Wi-Fi scans the QR code (or visits `http://<LAN-IP>:8080`), unlocks the **Web Audio API (`AudioContext`)**, pre-buffers the MP3 into RAM, and synchronizes with sub-5ms accuracy.
   - **Host Server:** Written in Go using a monotonic nanosecond clock (`time.Since(boot)`), serving MP3 files into device memory and running a low-jitter WebSocket control + NTP clock-sync responder.
2. **Native Standalone Mobile App (`flutter_app/`)**
   - **Why:** When there is no laptop/PC available and one phone must act as the standalone mobile server in a park or car.
   - **Stack:** Flutter (`dart:io` `HttpServer` for MP3 distribution, `RawDatagramSocket` for raw UDP clock synchronization, and `just_audio` for pitch-preserved playback rate drift correction).

---

## 2. Deep Dive: Clock Synchronization Math (Filtered NTP Burst)

Wall-clock time (`Date.now()`) is unsuitable for audio sync because OS background NTP daemons can jump the system clock forward or backward mid-song. Instead, every device uses its **monotonic clock**:
- **Host:** `T_host = time.Since(epoch).Microseconds() / 1000.0` (milliseconds with microsecond precision)
- **Client:** `T_client = performance.now()` (or `Stopwatch.elapsedMicroseconds` in Flutter)

### The 4-Timestamp Handshake
For each sync probe $i \in \{1 \dots N\}$ (where $N = 25$):
1. Client sends probe at local monotonic time $t_1$.
2. Host receives probe at host monotonic time $t_2$.
3. Host transmits response at host monotonic time $t_3$.
4. Client receives response at local monotonic time $t_4$.

From these four timestamps, we compute the **Round-Trip Time ($\text{RTT}_i$)** and the **Clock Offset ($\theta_i$)**:

$$\text{RTT}_i = (t_4 - t_1) - (t_3 - t_2)$$

$$\theta_i = \frac{(t_2 - t_1) + (t_3 - t_4)}{2}$$

Where the estimated Host time at any given Client time $t$ is:

$$\hat{T}_{\text{host}}(t) = t + \theta + \Delta_{\text{hw}}$$

($\Delta_{\text{hw}}$ is the user-adjustable hardware audio output latency calibration offset).

### Wi-Fi Jitter Rejection (Minimum-RTT Percentile Filter)
Wi-Fi (802.11) suffers from asymmetric contention and packet queuing spikes (e.g., 2ms on clear air vs. 80ms during beacon frames or retransmissions). When a packet is delayed in the router queue, the symmetric delay assumption breaks down.
- **Filter Algorithm:**
  1. Collect a burst of $N = 25$ samples spaced 25ms apart.
  2. Sort all samples in ascending order by $\text{RTT}_i$.
  3. Discard the slowest **60%** of samples (which experienced Wi-Fi queuing delay).
  4. Compute the **trimmed mean** of $\theta_i$ across the fastest 40% (lowest-RTT) samples, where queue delay was near zero and air-time was maximally symmetric.
  5. Continuously refine $\theta$ during playback using an Exponential Moving Average (EMA) only when an incoming heartbeat probe achieves an $\text{RTT} \le 1.3 \times \text{RTT}_{\min}$.

---

## 3. Deep Dive: Scheduled Start & PLL Drift Correction

### Sample-Accurate Scheduled Start
When the Host presses **Play** at track offset $P_0$ (in seconds):
1. The Host picks a target start time in the future:
   $$T_{\text{start}} = T_{\text{host\_now}} + \Delta_{\text{lead}}$$
   where $\Delta_{\text{lead}} = 1500\text{ ms}$ (1.5 seconds lead time so all phones receive the packet and prepare their audio pipelines).
2. Each Client receives `(T_start, P_0)` and computes the remaining wait time in its own monotonic clock domain:
   $$\Delta_{\text{wait\_sec}} = \frac{T_{\text{start}} - (\text{now}() + \theta) - \Delta_{\text{hw}}}{1000}$$
3. Using the Web Audio API (`AudioBufferSourceNode.start(audioCtx.currentTime + waitSec, P_0)`), the browser's C++ audio thread schedules the exact hardware audio sample frame to begin playback.

### Continuous Phase-Locked Loop (PLL) Drift Correction
Even after a perfect start, two phones' crystal oscillators (DAC sample clocks, e.g., `48000.02 Hz` vs `47999.91 Hz`) will slowly drift apart, or a phone starting late after `T_start` needs to join mid-song.

Every `250ms`, each Client evaluates its **Phase Error ($e$)**:
$$P_{\text{expected}} = P_0 + \frac{\hat{T}_{\text{host}}(t) - T_{\text{start}}}{1000}$$
$$e = P_{\text{expected}} - P_{\text{actual}} \quad (\text{in milliseconds})$$

Calling `seek()` on small errors causes an audible click/pop. Instead, we implement a **3-zone Proportional Controller (PLL)** on the audio playback rate $r$:

| Absolute Phase Error ($|e|$) | Zone | Action | Why |
| :--- | :--- | :--- | :--- |
| **$|e| < 2.5\text{ ms}$** | **Deadband (Locked)** | $r = 1.000$ | Inaudible to human ears (< 85 cm sound travel distance). Prevents micro-warbling. |
| **$2.5\text{ ms} \le |e| \le 45\text{ ms}$** | **Soft PLL Pull-In** | $r = \text{clamp}(1.0 + k_p \cdot e,\ 0.96,\ 1.04)$ where $k_p = 0.0008\text{ ms}^{-1}$ | Smoothly speeds up or slows down playback by up to $\pm 4\%$ for a few hundred milliseconds until error drops inside the `< 2.5ms` deadband. Zero clicks or pops. |
| **$|e| > 45\text{ ms}$** | **Hard Resync** | Immediate hard seek to $P_{\text{expected}} + \text{rebuffer\_comp}$ | Error is large enough (e.g., newly joined device or major OS stall) that immediate re-anchoring is faster than gradual pull-in. |
