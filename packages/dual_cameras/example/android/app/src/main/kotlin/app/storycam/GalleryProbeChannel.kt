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
 * - `saveScreenshot(name, bytes)`: writes a PNG in TWO places, and
 *   succeeds when at least one write lands (throws only when both
 *   fail — the mid-recording call site in the test guards the throw,
 *   so a save failure never fails the test):
 *   1. MediaStore.Downloads (DISPLAY_NAME + RELATIVE_PATH
 *      "Download/"), so the file lands at /sdcard/Download/<name>.
 *      No storage permission is needed for the app's own files in
 *      MediaStore.Downloads on API 29+ (official Android docs,
 *      "Storage updates in Android 11"). A Dart File write cannot be
 *      used here (scoped storage, API 30+) and Gal inserts into
 *      Images/Pictures only, never Download. This copy is the CI
 *      emulator `adb pull` path — it keeps working unchanged.
 *   2. A plain File in the app's external-files dir
 *      (getExternalFilesDir(null)), so the file also lands at
 *      /sdcard/Android/data/app.storycam/files/<name>. No permission
 *      needed for the app's own dir. This copy exists because a
 *      MediaStore-managed path was never verified pullable by
 *      Firebase Test Lab: the 2026-11-17 Test Lab run's bucket had no
 *      PNG/JPG at all, and no record shows --directories-to-pull was
 *      passed on that run. Test Lab pulls NO extra path by default —
 *      the proof-gate gcloud run must pass
 *      --directories-to-pull
 *      /sdcard/Download,/sdcard/Android/data/app.storycam/files
 *      (gcloud docs: absolute paths under /sdcard, /storage or
 *      /data/local/tmp; the Console UI has no such field). Either
 *      copy then lands in the results bucket under
 *      artifacts/sdcard/.... Flutter's takeScreenshot itself writes
 *      no file — it returns PNG bytes in memory only — so the probe
 *      is the only writer.
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
        // 1. MediaStore.Downloads -> /sdcard/Download/<name> (CI adb pull).
        var mediaOk = false
        var mediaError: String? = null
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/")
        }
        try {
            val uri = activity.contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            )
            if (uri == null) {
                mediaError = "MediaStore.Downloads insert returned null"
            } else {
                val stream = activity.contentResolver.openOutputStream(uri)
                if (stream == null) {
                    mediaError = "could not open output stream for $name"
                } else {
                    stream.use { it.write(bytes) }
                    mediaOk = true
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "saveScreenshot MediaStore failed for $name", t)
            mediaError = t.message
        }
        // 2. Plain file in the app's own external-files dir ->
        // /sdcard/Android/data/app.storycam/files/<name> (Test Lab
        // --directories-to-pull path; no permission needed, and a plain
        // File write needs no MediaStore round-trip).
        var fileOk = false
        var fileError: String? = null
        try {
            val dir = activity.getExternalFilesDir(null)
            if (dir == null) {
                fileError = "getExternalFilesDir returned null"
            } else {
                val outFile = java.io.File(dir, name)
                outFile.parentFile?.mkdirs()
                java.io.FileOutputStream(outFile).use { it.write(bytes) }
                fileOk = true
                Log.i(TAG, "saveScreenshot wrote ${outFile.absolutePath} (${bytes.size} B)")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "saveScreenshot external-files failed for $name", t)
            fileError = t.message
        }
        if (mediaOk || fileOk) {
            if (!mediaOk) Log.w(TAG, "saveScreenshot MediaStore failed: $mediaError")
            if (!fileOk) Log.w(TAG, "saveScreenshot external-files failed: $fileError")
            result.success(true)
        } else {
            result.error(
                "WRITE_FAILED",
                "both screenshot writes failed (MediaStore: $mediaError; " +
                    "external-files: $fileError)",
                null,
            )
        }
    }
}
