# SyncWave

Play one MP3 on many phones at the same time over Wi-Fi.

## How it works

1. One phone is the **Host**. It starts a tiny HTTP + WebSocket server on port `8080`,
   shows a QR code (`syncwave://join?ip=<host-ip>`) and its IP address.
2. Every other phone is a **Client**. It finds the Host automatically by scanning the
   local network, or you can type the Host IP by hand.
3. The Host sends the MP3 to every client; each client stores it **in RAM** and reports
   "ready".
4. The Host sends one `play` command with a timestamp 1.2 s in the future. Every client
   schedules the start on its own clock, so all phones begin together.
5. While playing, a small PLL keeps every phone within a few milliseconds of the Host
   by trimming the playback speed slightly (no clicks, no pitch change).

## Supported network setups

* Both phones on the same Wi-Fi router.
* The Host phone runs a **Personal Hotspot** and the other phone joins that hotspot.

Discovery only uses plain HTTP, so no extra permissions are required.

## Build

```bash
flutter pub get
flutter build apk --release
```

The APK is produced by GitHub Actions (see `.github/workflows/build-apk.yml`) and
published on the Releases page of the repository.
