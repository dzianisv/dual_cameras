package app.storycam

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * `dual_cameras_example/share` — share the just-recorded video via the
 * Android share sheet (issue #14) and delete it (issue #50). No new
 * dependency: ~30 lines of Kotlin per method following the
 * CaptionsChannel precedent (registered in MainActivity).
 *
 * - `shareVideo {path}` -> fires ACTION_SEND, type `video/mp4` (or
 *   the `video` wildcard when the extension is not .mp4), EXTRA_STREAM
 *   = FileProvider content URI, FLAG_GRANT_READ_URI_PERMISSION, wrapped
 *   in Intent.createChooser.
 * - `deleteVideo {path}` -> deletes the cache file AND the gallery row
 *   Gal saved for it (issue #50): the gallery row is resolved by
 *   MediaStore DISPLAY_NAME lookup (see findGalleryRow, A-F1) and
 *   deleted first; the cache file is deleted after it, so a
 *   user-cancelled system confirmation deletes nothing. Returns a map
 *   {cacheDeleted, galleryDeleted, cancelled}. On Android 11+ (API
 *   30+) the app owns the entry it created via Gal, so normally no
 *   dialog; if the platform raises RecoverableSecurityException (entry
 *   not owned — e.g. the user moved it), the channel launches the
 *   system confirmation via startIntentSenderForResult and completes
 *   the pending result from MainActivity.onActivityResult.
 *
 * FileProvider roots (res/xml/file_paths.xml) are cache-path + files-path.
 * Recordings land in cacheDir (upstream dual_cameras_android writes
 * `File(ctx.cacheDir, "dcr_*.mp4")`), so the shared/deleted file is
 * inside a declared root. The root check below logs the canonical path
 * against both roots and fails loudly with a channel error instead of
 * letting FileProvider throw IllegalArgumentException — a share failing
 * that way is a PR-blocking defect, not a runtime edge case.
 */
object ShareChannel {
    const val NAME = "dual_cameras_example/share"
    private const val TAG = "Share"
    private const val DELETE_REQUEST_CODE = 9101

    // Pending delete awaiting the system confirmation (issue #50): the
    // MethodChannel.Result is held until MainActivity.onActivityResult
    // reports the user's choice.
    private var pendingDeleteResult: MethodChannel.Result? = null
    private var pendingDeleteFile: File? = null
    private var pendingDeleteRowUri: Uri? = null

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "shareVideo" -> shareVideo(activity, call, result)
            "deleteVideo" -> deleteVideo(activity, call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * System-confirmation result for a pending deleteVideo (issue #50).
     * Called from MainActivity.onActivityResult. Returns true when the
     * request code was the delete one (whether or not a delete was
     * pending). RESULT_OK retries the row delete — the confirmation
     * grant now applies — then deletes the cache file; anything else
     * completes the pending result as cancelled, with nothing deleted.
     */
    fun onActivityResult(
        activity: Activity,
        requestCode: Int,
        resultCode: Int,
    ): Boolean {
        if (requestCode != DELETE_REQUEST_CODE) return false
        val result = pendingDeleteResult ?: return false
        val file = pendingDeleteFile
        val rowUri = pendingDeleteRowUri
        pendingDeleteResult = null
        pendingDeleteFile = null
        pendingDeleteRowUri = null
        if (resultCode != Activity.RESULT_OK || file == null || rowUri == null) {
            Log.i(TAG, "delete confirmation declined for ${file?.name}")
            result.success(mapOf(
                "cacheDeleted" to false,
                "galleryDeleted" to false,
                "cancelled" to true,
            ))
            return true
        }
        var galleryDeleted = false
        try {
            galleryDeleted =
                activity.contentResolver.delete(rowUri, null, null) > 0
        } catch (t: Throwable) {
            Log.e(TAG, "confirmed gallery row delete failed for ${file.name}", t)
        }
        val cacheDeleted = deleteCacheFile(file)
        result.success(mapOf(
            "cacheDeleted" to cacheDeleted,
            "galleryDeleted" to galleryDeleted,
            "cancelled" to false,
        ))
        return true
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

    private fun deleteVideo(
        activity: Activity,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (pendingDeleteResult != null) {
            return result.error(
                "delete_failed", "another delete is awaiting confirmation", null)
        }
        val path = call.argument<String>("path")
            ?: return result.error("delete_failed", "path required", null)
        val file = File(path)
        try {
            val canonical = file.canonicalFile
            val roots = listOf(
                activity.cacheDir.canonicalFile,
                activity.filesDir.canonicalFile,
            )
            check(roots.any { canonical.path.startsWith(it.path + File.separator) }) {
                "file outside FileProvider roots: ${canonical.absolutePath}"
            }
            val attempt = deleteVideoInternal(activity, canonical)
            if (attempt.pendingRowUri != null) {
                // System confirmation launched: hold the result until
                // MainActivity.onActivityResult reports the choice.
                pendingDeleteResult = result
                pendingDeleteFile = canonical
                pendingDeleteRowUri = attempt.pendingRowUri
                return
            }
            result.success(mapOf(
                "cacheDeleted" to attempt.cacheDeleted,
                "galleryDeleted" to attempt.galleryDeleted,
                "cancelled" to false,
            ))
        } catch (t: Throwable) {
            Log.e(TAG, "delete failed for $path", t)
            result.error(
                "delete_failed", t.message ?: t.javaClass.simpleName, null)
        }
    }

    private data class DeleteAttempt(
        val cacheDeleted: Boolean,
        val galleryDeleted: Boolean,
        // Non-null when the system confirmation was launched: the
        // result is held until onActivityResult, and nothing has been
        // deleted yet.
        val pendingRowUri: Uri? = null,
    )

    /**
     * Gallery row first, cache file last (issue #50): a user-cancelled
     * system confirmation must delete nothing, so the cache file is
     * only touched after the gallery row is gone (or confirmed absent).
     * A gallery failure that is not a RecoverableSecurityException
     * still deletes the cache file — the Dart side reports that as a
     * partial failure, per the design.
     */
    private fun deleteVideoInternal(
        activity: Activity,
        file: File,
    ): DeleteAttempt {
        val rowUri = findGalleryRow(activity, file)
        var galleryDeleted = false
        when (rowUri) {
            is GalleryRow.Found -> {
                when (deleteGalleryRow(activity, rowUri.uri, file)) {
                    GalleryDelete.Deleted -> galleryDeleted = true
                    GalleryDelete.Failed -> galleryDeleted = false
                    GalleryDelete.NeedsConfirmation -> {
                        // System confirmation launched: hold the result;
                        // nothing has been deleted yet.
                        return DeleteAttempt(
                            cacheDeleted = false,
                            galleryDeleted = false,
                            pendingRowUri = rowUri.uri,
                        )
                    }
                }
            }
            GalleryRow.NotFound -> {
                // No gallery row (already removed from Photos, or the
                // lookup missed): nothing is kept in the gallery.
                Log.i(TAG, "no gallery row for ${file.name}; nothing to delete there")
                galleryDeleted = true
            }
            GalleryRow.LookupFailed -> {
                // The lookup itself failed: do not claim the gallery copy
                // is gone — the Dart side reports a partial failure.
                Log.w(TAG, "gallery lookup failed for ${file.name}; keeping gallery state unknown")
                galleryDeleted = false
            }
        }
        return DeleteAttempt(
            cacheDeleted = deleteCacheFile(file),
            galleryDeleted = galleryDeleted,
        )
    }

    private sealed interface GalleryDelete {
        data object Deleted : GalleryDelete
        data object Failed : GalleryDelete
        data object NeedsConfirmation : GalleryDelete
    }

    /**
     * Delete one gallery row. NeedsConfirmation when the platform raises
     * RecoverableSecurityException (the system confirmation was launched
     * and the result is held until onActivityResult).
     */
    private fun deleteGalleryRow(
        activity: Activity,
        rowUri: Uri,
        file: File,
    ): GalleryDelete {
        try {
            val deleted = activity.contentResolver.delete(rowUri, null, null)
            if (deleted <= 0) {
                Log.w(TAG, "gallery row delete affected 0 rows for ${file.name}")
                return GalleryDelete.Failed
            }
            return GalleryDelete.Deleted
        } catch (e: SecurityException) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                e is RecoverableSecurityException
            ) {
                // Entry not owned (e.g. the user moved it): the system
                // confirmation is the "platform confirmation if
                // required". The cache file is NOT deleted yet.
                val sender = e.userAction?.actionIntent?.intentSender
                if (sender != null) {
                    activity.startIntentSenderForResult(
                        sender, DELETE_REQUEST_CODE, null, 0, 0, 0, null)
                    return GalleryDelete.NeedsConfirmation
                }
                Log.e(TAG, "RecoverableSecurityException without action for ${file.name}")
                return GalleryDelete.Failed
            }
            Log.e(TAG, "gallery row delete denied for ${file.name}", e)
            return GalleryDelete.Failed
        } catch (t: Throwable) {
            Log.e(TAG, "gallery row delete failed for ${file.name}", t)
            return GalleryDelete.Failed
        }
    }

    /** True when the file is gone afterwards (already gone counts). */
    private fun deleteCacheFile(file: File): Boolean {
        return try {
            !file.exists() || file.delete()
        } catch (t: Throwable) {
            Log.e(TAG, "cache delete failed for ${file.absolutePath}", t)
            false
        }
    }

    private sealed interface GalleryRow {
        data class Found(val uri: Uri) : GalleryRow
        data object NotFound : GalleryRow
        // The lookup failed, or several same-name rows exist and none
        // can be proven to be this file's copy: never guess — the Dart
        // side reports a partial failure instead of claiming the copy
        // is gone.
        data object LookupFailed : GalleryRow
    }

    /**
     * Resolve the MediaStore row Gal saved for [file] (issue #50, A-F1).
     * Verified against gal 2.3.3 (resolved from gal ^2.3.0): putVideo
     * inserts into MediaStore.Video with DISPLAY_NAME = the file's
     * basename, RELATIVE_PATH = Movies/, and copies the bytes verbatim —
     * so the row's SIZE equals the file's length. If a same-named video
     * already sat in Movies/, Gal retries with a numeric suffix
     * (dcr_x1.mp4, dcr_x2.mp4), so the exact-name lookup can miss: the
     * fallback matches stem + digits + extension and still requires the
     * SIZE match, so a stranger's row (same name, different bytes) is
     * never deleted. Cache files are dcr_<nanoTime>.mp4, so a same-name
     * row is near-impossible in practice; the SIZE filter is the
     * belt-and-braces.
     */
    private fun findGalleryRow(activity: Activity, file: File): GalleryRow {
        val name = file.name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        val length = if (file.exists()) file.length() else null
        val resolver = activity.contentResolver
        val uri = MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
        )
        data class Row(val id: Long, val displayName: String, val size: Long?, val added: Long)

        fun query(selection: String, args: Array<String>): List<Row>? {
            val rows = mutableListOf<Row>()
            try {
                resolver.query(uri, projection, selection, args, null)?.use { c ->
                    val idCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                    val nameCol =
                        c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                    val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                    val addedCol =
                        c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
                    while (c.moveToNext()) {
                        rows.add(Row(
                            id = c.getLong(idCol),
                            displayName = c.getString(nameCol) ?: "",
                            size = if (c.isNull(sizeCol)) null else c.getLong(sizeCol),
                            added = c.getLong(addedCol),
                        ))
                    }
                }
            } catch (t: Throwable) {
                Log.e(TAG, "gallery lookup failed for $name", t)
                return null
            }
            return rows
        }

        val exact = query(
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
            arrayOf(name),
        ) ?: return GalleryRow.LookupFailed
        // Suffix pattern Gal uses on a name clash: stem + digits + ext.
        val suffixPattern =
            Regex("^${Regex.escape(stem)}\\d*${Regex.escape(ext)}$")
        val suffixed = if (exact.isEmpty()) {
            query(
                "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?",
                arrayOf("$stem%$ext"),
            )?.filter { suffixPattern.matches(it.displayName) }
                ?: return GalleryRow.LookupFailed
        } else {
            emptyList()
        }
        val candidates = exact + suffixed
        if (candidates.isEmpty()) {
            Log.i(TAG, "no gallery row named $name (or suffixed) for delete")
            return GalleryRow.NotFound
        }
        // Prefer a SIZE match — Gal copies the bytes verbatim. With no
        // file to measure, or no SIZE match, fall back to the single
        // exact-name row (a dcr_<nanoTime> name is unique per recording)
        // or, failing that, the latest row: never guess between several
        // same-name rows.
        val sizeMatched = if (length != null) {
            candidates.filter { it.size == length }
        } else {
            emptyList()
        }
        val chosen = when {
            sizeMatched.isNotEmpty() -> sizeMatched.maxByOrNull { it.added }
            exact.size == 1 -> exact.first()
            candidates.size == 1 -> candidates.first()
            else -> null
        }
        if (chosen == null) {
            Log.w(TAG, "ambiguous gallery rows for $name (${candidates.size}); deleting none")
            return GalleryRow.LookupFailed
        }
        Log.i(TAG, "gallery row for $name: id=${chosen.id} " +
            "displayName=${chosen.displayName} size=${chosen.size}")
        return GalleryRow.Found(ContentUris.withAppendedId(uri, chosen.id))
    }
}
