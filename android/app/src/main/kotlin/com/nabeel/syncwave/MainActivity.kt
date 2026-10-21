package com.nabeel.syncwave

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small platform channel that exposes the pieces of the audio path that Dart
 * cannot see:
 *
 *  * the estimated output latency of this phone (the AudioTrack/HAL buffer
 *    delay). It is the reason two phones can sound out of sync even when
 *    their players are perfectly aligned.
 *  * a persisted per-device manual nudge, so a user can trim the remaining
 *    difference by ear (Bluetooth and wired outputs have very different
 *    latencies that cannot be derived automatically).
 */
class MainActivity : FlutterActivity() {

    private val channelName = "syncwave/device"
    private val prefs by lazy {
        getSharedPreferences("syncwave", Context.MODE_PRIVATE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "outputLatencyMs" -> result.success(estimateOutputLatencyMs())
                    "measuredLatencyMs" -> {
                        // The measurement takes ~250 ms: keep it off the UI thread.
                        Thread {
                            val ms = measureOutputLatencyMs()
                            runOnUiThread { result.success(ms) }
                        }.start()
                    }
                    "getOffsetMs" -> result.success(prefs.getInt("offset_ms", 0))
                    "setOffsetMs" -> {
                        val value = call.argument<Int>("value") ?: 0
                        prefs.edit().putInt("offset_ms", value).apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Output latency in milliseconds, derived from the audio HAL buffer size:
     *   latency ~= framesPerBuffer / sampleRate
     * This is the same estimate Chrome uses for AudioContext.outputLatency.
     */
    private fun estimateOutputLatencyMs(): Double {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            var frames = 0
            var rate = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                frames = am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)
                    ?.toIntOrNull() ?: 0
                rate = am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
                    ?.toIntOrNull() ?: 0
            }
            if (frames > 0 && rate > 0) {
                frames * 1000.0 / rate
            } else {
                0.0
            }
        } catch (e: Exception) {
            0.0
        }
    }

    /**
     * Measures the real output latency of this device.
     *
     * A silent AudioTrack is played and its presentation timestamp is read:
     * AudioTrack.getTimestamp() reports which frame was heard at which
     * instant, so the delay between "written" and "heard" is measurable
     * instead of guessed. This includes the HAL buffer *and* the DSP effects
     * (spatial audio, equalizers) that the buffer estimate misses.
     *
     * Returns 0 if the device does not provide a timestamp.
     */
    private fun measureOutputLatencyMs(): Double {
        var track: AudioTrack? = null
        return try {
            val rate = 48000
            val minBuf = AudioTrack.getMinBufferSize(
                rate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBuf <= 0) return 0.0

            track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(minBuf * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            track.setVolume(0f) // silent: only used for the measurement
            track.play()

            val silence = ShortArray(minBuf)
            val deadline = System.nanoTime() + 250_000_000L // 250 ms
            while (System.nanoTime() < deadline) {
                track.write(silence, 0, silence.size)
                Thread.sleep(15)
            }

            val timestamp = AudioTimestamp()
            if (!track.getTimestamp(timestamp)) return 0.0

            val nowNs = System.nanoTime()
            val playedFrames =
                track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            val pending = (playedFrames - timestamp.framePosition).coerceAtLeast(0)
            // Frames written but not yet heard + time since the snapshot.
            (nowNs - timestamp.nanoTime) / 1_000_000.0 +
                pending * 1000.0 / rate
        } catch (e: Exception) {
            0.0
        } finally {
            try {
                track?.stop()
            } catch (_: Exception) {
            }
            try {
                track?.release()
            } catch (_: Exception) {
            }
        }
    }
}
