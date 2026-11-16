package app.storycam

import android.app.Activity
import android.content.ContentValues
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Test-only probe channel for the camera-flow instrumentation test
 * (issue #79, Track B step 2). Registered in MainActivity next to
 * ShareChannel. No product code calls it; only
 * `integration_test/camera_flow_test.dart` (via `gallery_probe.dart`).
 *
 * - `queryLatest()` (read-only): the newest MediaStore video row by
 *   DATE_ADDED (tie-break _ID), as {durationMs, size, dateAdded}, or
 *   null when no video row exists. Reuses the ShareChannel
 *   findGalleryRow query shape (MediaStore video query) with the
 *   DURATION column added to the projection. A row with durationMs == 0
 *   means the MediaStore scanner has not filled DURATION yet — the test
 *   polls until durationMs > 0 instead of failing on it.
 * - `saveScreenshot(name, bytes)`: writes a PNG into
 *   MediaStore.Downloads (DISPLAY_NAME + RELATIVE_PATH "Download/"),
 *   so the file lands at /sdcard/Download/<name>. No storage
 *   permission is needed for the app's own files in MediaStore.Downloads
 *   on API 29+ (official Android docs, "Storage updates in Android 11").
 *   A Dart File write cannot be used here (scoped storage, API 30+)
 *   and Gal inserts into Images/Pictures only, never Download.
 */
object GalleryProbeChannel {
    const val NAME = "app.storycam/gallery_probe"
    private const val TAG = "GalleryProbe"

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "queryLatest" -> queryLatest(activity, result)
            "saveScreenshot" -> saveScreenshot(activity, call, result)
            else -> result.notImplemented()
        }
    }

    private fun queryLatest(activity: Activity, result: MethodChannel.Result) {
        val uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.Video.VideoColumns.DURATION,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
        )
        try {
            activity.contentResolver.query(
                uri,
                projection,
                null,
                null,
                "${MediaStore.MediaColumns.DATE_ADDED} DESC, " +
                    "${MediaStore.MediaColumns._ID} DESC",
            )?.use { c ->
                if (!c.moveToFirst()) {
                    result.success(null)
                    return
                }
                val durationCol =
                    c.getColumnIndexOrThrow(MediaStore.Video.VideoColumns.DURATION)
                val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val addedCol =
                    c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                result.success(
                    mapOf(
                        "durationMs" to c.getLong(durationCol),
                        "size" to if (c.isNull(sizeCol)) 0L else c.getLong(sizeCol),
                        "dateAdded" to c.getLong(addedCol),
                    ),
                )
            } ?: result.success(null)
        } catch (t: Throwable) {
            Log.e(TAG, "queryLatest failed", t)
            result.error("QUERY_FAILED", t.message, null)
        }
    }

    private fun saveScreenshot(
        activity: Activity,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val name = call.argument<String>("name")
        val bytes = call.argument<ByteArray>("bytes")
        if (name.isNullOrEmpty() || bytes == null) {
            result.error("BAD_ARGS", "saveScreenshot needs name + bytes", null)
            return
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/")
        }
        try {
            val uri = activity.contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            ) ?: run {
                result.error(
                    "INSERT_FAILED",
                    "MediaStore.Downloads insert returned null",
                    null,
                )
                return
            }
            activity.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: run {
                    result.error(
                        "WRITE_FAILED",
                        "could not open output stream for $name",
                        null,
                    )
                    return
                }
            result.success(true)
        } catch (t: Throwable) {
            Log.e(TAG, "saveScreenshot failed for $name", t)
            result.error("WRITE_FAILED", t.message, null)
        }
    }
}
