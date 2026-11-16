package app.storycam

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.util.Log
import java.io.File
import kotlin.math.roundToInt

/**
 * Draws the map circle into a video frame during the post-process burn
 * (issue #49, design §1 + §5).
 *
 * Snapshots are the complete render: each 2 fps RepaintBoundary snapshot
 * of MapCircle already contains the rotated tiles, the placed N badge, the
 * centered dot and the circular clip — so [draw]
 * paints the snapshot as-is and never rotates anything. The track's only
 * roles are gating mapVisible (draw nothing from the time the map was
 * toggled off) and the fallback disc (no snapshot yet = plain disc +
 * N arrow). lat/lng and heading have no role here.
 *
 * Geometry (design §4): on screen the circle is 120 logical px across
 * with 16 logical px left padding, on a 412 logical px wide screen —
 * so in video pixels the diameter is w * 120/412 (315 px at 1080p,
 * 630 px at 4K) and the padding is w * 16/412 (42 px at 1080p, 84 px
 * at 4K), computed at runtime from the actual frame width. The snapshot
 * itself was rendered at burn diameter at capture time, so it is drawn
 * at its intrinsic size; only the padding is computed here.
 */
object MapRenderer {
    private const val TAG = "MapRenderer"

    /**
     * One time-keyed entry of the burn manifest. [file] is the snapshot
     * PNG (null for a visibility-only sample: a map toggle, or a tick
     * while the map was off); [tMs] is take-relative milliseconds;
     * [mapVisible] is whether the map was on screen at that time.
     */
    data class Frame(val file: File?, val tMs: Long, val mapVisible: Boolean)

    // Bitmap cache: the same snapshot is held for ~500 ms (~15 frames at
    // 30 fps), so decode once per snapshot change, never once per frame.
    // Valid only within one burn — CaptionBurner calls [reset] first.
    // Burns are serialized on the Dart side (one _captionQueue), so no
    // concurrent burn can interleave here.
    private var cachedFile: File? = null
    private var cachedBitmap: Bitmap? = null

    fun reset() {
        cachedBitmap?.recycle()
        cachedBitmap = null
        cachedFile = null
    }

    /**
     * Draw the map for time [tSec] onto [canvas] (already sized w×h).
     * Map first, captions after (the caller draws KaraokeRenderer next).
     */
    fun draw(canvas: Canvas, frames: List<Frame>, tSec: Double, w: Int, h: Int) {
        if (frames.isEmpty()) return
        val nowMs = (tSec * 1000).toLong()
        // Latest entry at or before now. Snapshots and visibility samples
        // share one time-ordered list, so this is both the visibility gate
        // and the snapshot pick.
        val entry = frames.lastOrNull { it.tMs <= nowMs }
        if (entry == null) {
            // Take just started, first snapshot not landed yet: the map was
            // on screen, so show the fallback disc, never a crash.
            drawFallbackDisc(canvas, w)
            return
        }
        if (!entry.mapVisible) return // toggled off: draw nothing from here
        val file = entry.file
        if (file == null) {
            // Toggled back on; the first new snapshot is <= 500 ms away.
            // The pre-toggle snapshot is stale and must not be shown, so
            // the fallback disc covers the gap instead.
            drawFallbackDisc(canvas, w)
            return
        }
        val bitmap = bitmapFor(file)
        if (bitmap == null) {
            Log.w(TAG, "snapshot unreadable, fallback disc: ${file.path}")
            drawFallbackDisc(canvas, w)
            return
        }
        val padding = (w * 16 / 412.0).roundToInt()
        canvas.drawBitmap(
            bitmap, null,
            Rect(padding, padding,
                padding + bitmap.width, padding + bitmap.height),
            null,
        )
    }

    private fun bitmapFor(file: File): Bitmap? {
        val cached = cachedBitmap
        if (cachedFile == file && cached != null && !cached.isRecycled) {
            return cached
        }
        cachedBitmap?.recycle()
        cachedBitmap = null
        cachedFile = null
        return try {
            BitmapFactory.decodeFile(file.path)?.also {
                cachedBitmap = it
                cachedFile = file
            }
        } catch (t: Throwable) {
            Log.w(TAG, "decode failed: ${file.path}", t)
            null
        }
    }

    // Fallback disc (no snapshot yet): the on-screen no-position disc —
    // #E8F0E4 fill with the red-pink N badge at the top (map_circle.dart).
    private val discPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#E8F0E4")
        style = Paint.Style.FILL
    }
    private val nPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#FF526D")
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textAlign = Paint.Align.CENTER
    }

    private fun drawFallbackDisc(canvas: Canvas, w: Int) {
        val padding = (w * 16 / 412.0).roundToInt()
        val d = (w * 120 / 412.0).roundToInt() // 315 px at 1080p, 630 at 4K
        val cx = padding + d / 2f
        val cy = padding + d / 2f
        canvas.drawCircle(cx, cy, d / 2f, discPaint)
        // N badge: 13 logical px bold, 5 logical px top padding on screen.
        nPaint.textSize = d * 13f / 120f
        val topPad = (w * 5 / 412.0).toFloat()
        canvas.drawText("N", cx, padding + topPad + nPaint.textSize, nPaint)
    }

    /**
     * Parse the Dart map manifest JSON:
     * {"dir": ".../map_frames_<takeId>",
     *  "frames": [{"file": "map_0.png"|null, "tMs": 0, "mapVisible": true}]}
     *
     * Returns null when [json] is null (map off) or carries no snapshot —
     * the caller then runs the existing captions-only path, unchanged.
     * Field order inside each object does not matter.
     */
    fun parseManifest(json: String?): List<Frame>? {
        if (json == null) return null
        val dirMatch =
            Regex(""""dir"\s*:\s*"((?:[^"\\]|\\.)*)"""").find(json) ?: return null
        val dir = File(dirMatch.groupValues[1])
        val framesArray = json.substringAfter("\"frames\"", "")
        val frames = mutableListOf<Frame>()
        for (m in Regex("""\{([^{}]*)\}""").findAll(framesArray)) {
            val body = m.groupValues[1]
            val tMs = Regex(""""tMs"\s*:\s*([0-9]+)""")
                .find(body)?.groupValues?.get(1)?.toLongOrNull() ?: continue
            val visible = Regex(""""mapVisible"\s*:\s*(true|false)""")
                .find(body)?.groupValues?.get(1)?.toBoolean() ?: continue
            val fileName = Regex(""""file"\s*:\s*"([^"]*)"""")
                .find(body)?.groupValues?.get(1)
            frames.add(
                Frame(
                    file = if (fileName.isNullOrEmpty()) null else File(dir, fileName),
                    tMs = tMs,
                    mapVisible = visible,
                ),
            )
        }
        if (frames.none { it.file != null }) return null
        return frames.sortedBy { it.tMs }
    }
}
