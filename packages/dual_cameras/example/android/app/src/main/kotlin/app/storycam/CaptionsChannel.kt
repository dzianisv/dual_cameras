package app.storycam

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * `dual_cameras_example/captions` — auto-captions post-processing for the
 * example app (kept out of the dual_cameras plugin packages on purpose).
 *
 * - `extractAudio {mp4}` -> absolute path of a 16 kHz mono WAV.
 * - `burnCaptions {mp4, words}` -> absolute path of the captioned .mp4
 *   (`words` = JSON array of {"text","start","end"} in seconds).
 *
 * Heavy work runs on a background thread; results post back on the main
 * thread as the MethodChannel contract requires.
 */
object CaptionsChannel {
    const val NAME = "dual_cameras_example/captions"
    private const val TAG = "Captions"
    private val mainHandler = Handler(Looper.getMainLooper())

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "extractAudio" -> runBg(result) {
                val mp4 = call.argument<String>("mp4")
                    ?: throw IllegalArgumentException("mp4 required")
                val wav = File(activity.cacheDir,
                    "cap_${System.nanoTime()}.wav").absolutePath
                AudioExtractor.extractToWav(mp4, wav)
                wav
            }
            "burnCaptions" -> runBg(result) {
                val mp4 = call.argument<String>("mp4")
                    ?: throw IllegalArgumentException("mp4 required")
                val words = call.argument<String>("words") ?: "[]"
                val out = File(activity.cacheDir,
                    "cap_${System.nanoTime()}_captioned.mp4").absolutePath
                CaptionBurner.burn(mp4, words, out)
            }
            else -> result.notImplemented()
        }
    }

    private fun runBg(
        result: MethodChannel.Result,
        block: () -> String,
    ) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (t: Throwable) {
                Log.e(TAG, "captions failed", t)
                mainHandler.post { result.error("captions_failed",
                    t.message ?: t.javaClass.simpleName, null) }
            }
        }.apply { isDaemon = true }.start()
    }
}
