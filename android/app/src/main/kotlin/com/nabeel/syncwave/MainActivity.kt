package com.nabeel.syncwave

import android.content.Context
import android.media.AudioManager
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
}
