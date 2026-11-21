package app.storycam

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
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
 * The frame is decoded downsampled, not just scaled after a full-res
 * decode (issue #106): on API 30+ `getScaledFrameAtTime` decodes only
 * the pixels the thumbnail needs, instead of a full 1080p/4K frame
 * that `createScaledBitmap` then throws away. The pre-30 fallback
 * still decodes full-res and scales down — see decodeFrame.
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
            val frame = decodeFrame(retriever, timeMs, maxWidth)
                ?: return result.error(
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

    /**
     * Decodes one frame at thumbnail size. On API 30+
     * [MediaMetadataRetriever.getScaledFrameAtTime] decodes the frame
     * already downsampled to at most `maxWidth` wide, so a 1080p/4K
     * video never materialises as a full-resolution bitmap; on older
     * APIs it falls back to a full-res decode plus a scale-down.
     *
     * The `createScaledBitmap` guard in [videoThumbnail] stays in
     * place after this call: it trims whatever the retriever returns
     * to exactly `maxWidth` wide, so the output is identical on every
     * API level (128 px wide, quality 75 by default).
     */
    private fun decodeFrame(
        retriever: MediaMetadataRetriever,
        timeMs: Int,
        maxWidth: Int,
    ): Bitmap? {
        val timeUs = timeMs * 1000L
        // Pre-API-30 fallback (minSdk is 21, the Flutter default, so
        // this path is live, not dead code): getScaledFrameAtTime
        // needs API 30, so decode full-res and let videoThumbnail
        // scale it down after. Design rule from issue #106 — cap the
        // decode, not just the output — so this fallback is the
        // exception, not the pattern: any new thumbnail path must
        // downsample at decode time on the APIs that allow it.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return retriever.getFrameAtTime(
                timeUs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            )
        }
        // Display dimensions come from metadata (cheap, no decode).
        // The width/height keys describe the encoded frame; a 90°/270°
        // rotation swaps the displayed dimensions — the retriever
        // returns the frame already rotated, so the aspect used for the
        // target height must use the displayed size.
        val videoWidth = retriever.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
        )?.toIntOrNull() ?: 0
        val videoHeight = retriever.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
        )?.toIntOrNull() ?: 0
        val rotation = retriever.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
        )?.toIntOrNull() ?: 0
        val displayWidth =
            if (rotation == 90 || rotation == 270) videoHeight else videoWidth
        val displayHeight =
            if (rotation == 90 || rotation == 270) videoWidth else videoHeight
        if (displayWidth <= maxWidth || displayWidth <= 0 || displayHeight <= 0) {
            // Already thumbnail-sized (or dimensions unknown): a
            // full-res decode costs nothing at this size, so keep the
            // plain path instead of asking the retriever to upscale.
            return retriever.getFrameAtTime(
                timeUs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            )
        }
        val targetHeight = (displayHeight * maxWidth / displayWidth.toDouble())
            .toInt().coerceAtLeast(1)
        return retriever.getScaledFrameAtTime(
            timeUs,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            maxWidth,
            targetHeight,
        )
    }
}
