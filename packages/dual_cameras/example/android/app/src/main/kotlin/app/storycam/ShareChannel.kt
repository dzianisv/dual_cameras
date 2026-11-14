package app.storycam

import android.app.Activity
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * `dual_cameras_example/share` — share the just-recorded video via the
 * Android share sheet (issue #14). No new dependency: ~30 lines of Kotlin
 * following the CaptionsChannel precedent (registered in MainActivity).
 *
 * - `shareVideo {path}` -> fires ACTION_SEND, type `video/mp4` (or
 *   the `video` wildcard when the extension is not .mp4), EXTRA_STREAM
 *   = FileProvider content URI, FLAG_GRANT_READ_URI_PERMISSION, wrapped
 *   in Intent.createChooser.
 *
 * FileProvider roots (res/xml/file_paths.xml) are cache-path + files-path.
 * Recordings land in cacheDir (upstream dual_cameras_android writes
 * `File(ctx.cacheDir, "dcr_*.mp4")`), so the shared file is inside a
 * declared root. The root check below logs the canonical path against
 * both roots and fails loudly with a channel error instead of letting
 * FileProvider throw IllegalArgumentException — a share failing that
 * way is a PR-blocking defect, not a runtime edge case.
 */
object ShareChannel {
    const val NAME = "dual_cameras_example/share"
    private const val TAG = "Share"

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareVideo" -> shareVideo(activity, call, result)
            else -> result.notImplemented()
        }
    }

    private fun shareVideo(
        activity: Activity,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val path = call.argument<String>("path")
            ?: return result.error("share_failed", "path required", null)
        val file = File(path)
        if (!file.exists()) {
            return result.error(
                "share_failed", "file no longer exists: $path", null)
        }
        try {
            val canonical = file.canonicalFile
            val roots = listOf(
                activity.cacheDir.canonicalFile,
                activity.filesDir.canonicalFile,
            )
            Log.i(TAG, "sharing ${canonical.absolutePath} " +
                "(roots: ${roots.joinToString { it.absolutePath }})")
            check(roots.any { canonical.path.startsWith(it.path + File.separator) }) {
                "shared file outside FileProvider roots: ${canonical.absolutePath}"
            }
            val mime = if (path.endsWith(".mp4", ignoreCase = true)) {
                "video/mp4"
            } else {
                "video/*"
            }
            val uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                canonical,
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(intent, "Share video"))
            result.success(null)
        } catch (t: Throwable) {
            Log.e(TAG, "share failed for $path", t)
            result.error(
                "share_failed", t.message ?: t.javaClass.simpleName, null)
        }
    }
}
