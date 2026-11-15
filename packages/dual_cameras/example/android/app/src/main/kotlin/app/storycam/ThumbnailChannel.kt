package app.storycam

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * `dual_cameras_example/thumbnail` — one frame of the last video as JPEG
 * bytes (issue #50). Own channel, not the share channel: the thumbnail
 * is a read-only frame extraction whose failure is an invisible fallback
 * on the Dart side, while share/delete failures set status — and the
 * widget tests mock the two channels independently. Registered in
 * MainActivity, following the CaptionsChannel precedent.
 *
 * - `videoThumbnail {path, maxWidth, quality, timeMs}` -> JPEG bytes
 *   (Uint8List on the Dart side) of the frame at `timeMs` (default 500:
 *   the first frame is often black), scaled so the width is at most
 *   `maxWidth` (default 128) with the height auto-scaled to the source
 *   aspect, compressed at `quality` (default 75). iOS mirrors this
 *   with AVAssetImageGenerator (AppDelegate.swift).
 *
 * No new dependency: video_thumbnail 0.5.6 was removed — its
 * android/build.gradle calls jcenter(), which is gone under this
 * project's AGP 9+ setup, and 0.5.6 is the latest version on pub.dev,
 * so no newer release fixes it.
 */
object ThumbnailChannel {
    const val NAME = "dual_cameras_example/thumbnail"
    private const val TAG = "Thumbnail"

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "videoThumbnail" -> videoThumbnail(call, result)
            else -> result.notImplemented()
        }
    }

    private fun videoThumbnail(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
            ?: return result.error("thumbnail_failed", "path required", null)
        val maxWidth = (call.argument<Int>("maxWidth") ?: 128).coerceAtLeast(1)
        val quality = (call.argument<Int>("quality") ?: 75).coerceIn(0, 100)
        val timeMs = (call.argument<Int>("timeMs") ?: 500).coerceAtLeast(0)
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                timeMs * 1000L,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return result.error(
                "thumbnail_failed", "no frame at ${timeMs}ms: $path", null)
            val scaled = if (frame.width > maxWidth) {
                val height = (frame.height * maxWidth / frame.width.toDouble())
                    .toInt().coerceAtLeast(1)
                Bitmap.createScaledBitmap(frame, maxWidth, height, true)
            } else {
                frame
            }
            val out = ByteArrayOutputStream()
            try {
                if (!scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)) {
                    return result.error(
                        "thumbnail_failed", "JPEG encode failed: $path", null)
                }
                result.success(out.toByteArray())
            } finally {
                out.close()
                if (scaled !== frame) scaled.recycle()
                frame.recycle()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "thumbnail failed for $path", t)
            result.error(
                "thumbnail_failed", t.message ?: t.javaClass.simpleName, null)
        } finally {
            try {
                retriever.release()
            } catch (t: Throwable) {
                Log.e(TAG, "retriever release failed for $path", t)
            }
        }
    }
}
