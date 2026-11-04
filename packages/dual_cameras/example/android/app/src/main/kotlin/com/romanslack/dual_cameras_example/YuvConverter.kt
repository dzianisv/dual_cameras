package com.romanslack.dual_cameras_example

import android.graphics.Bitmap
import android.media.Image

/**
 * Converts an [Image] in YUV_420_888 to an ARGB_8888 [Bitmap].
 * Handles arbitrary row/pixel strides (no assumption of tight packing).
 */
object YuvConverter {
    fun toBitmap(image: Image): Bitmap {
        val bitmap = Bitmap.createBitmap(
            image.width, image.height, Bitmap.Config.ARGB_8888)
        toBitmap(image, bitmap, IntArray(image.width * image.height))
        return bitmap
    }

    /** Variant that reuses [bitmap] and [argb] across frames (no allocation). */
    fun toBitmap(image: Image, bitmap: Bitmap, argb: IntArray) {
        val w = image.width
        val h = image.height
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val yRowStride = yPlane.rowStride
        val uvRowStride = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride

        val out = argb
        val yRow = ByteArray(yRowStride)
        val uRow = ByteArray(uvRowStride)
        val vRow = ByteArray(uvRowStride)
        for (row in 0 until h) {
            yBuf.position(row * yRowStride)
            yBuf.get(yRow, 0, yRowStride.coerceAtMost(yBuf.remaining()))
            val uvRow = row / 2
            uBuf.position(uvRow * uvRowStride)
            uBuf.get(uRow, 0, uvRowStride.coerceAtMost(uBuf.remaining()))
            vBuf.position(uvRow * uvRowStride)
            vBuf.get(vRow, 0, uvRowStride.coerceAtMost(vBuf.remaining()))
            for (col in 0 until w) {
                val y = (yRow[col].toInt() and 0xff)
                val u = (uRow[(col / 2) * uvPixelStride].toInt() and 0xff) - 128
                val v = (vRow[(col / 2) * uvPixelStride].toInt() and 0xff) - 128
                // BT.601 full-range-ish conversion.
                var r = (y + 1.402f * v).toInt()
                var g = (y - 0.344136f * u - 0.714136f * v).toInt()
                var b = (y + 1.772f * u).toInt()
                r = r.coerceIn(0, 255)
                g = g.coerceIn(0, 255)
                b = b.coerceIn(0, 255)
                out[row * w + col] = 0xff000000.toInt() or (r shl 16) or (g shl 8) or b
            }
        }
        bitmap.setPixels(out, 0, w, 0, 0, w, h)
    }
}
