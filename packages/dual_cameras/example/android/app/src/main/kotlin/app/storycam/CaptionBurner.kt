package app.storycam

import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.nio.ByteBuffer

/**
 * Burns karaoke word-highlight captions into a copy of [mp4Path].
 *
 * Pipeline (all CPU, no GL, no ffmpeg): video track -> MediaCodec decoder ->
 * ImageReader (YUV_420_888) -> ARGB Bitmap -> Canvas karaoke overlay ->
 * NV12/I420 -> MediaCodec encoder (byte-buffer mode, exact PTS) ->
 * MediaMuxer, with the original audio track passed through untouched.
 *
 * Alpha-grade: optimized for correctness, not speed. Buffers are reused
 * across frames to avoid GC churn.
 */
object CaptionBurner {
    private const val TAG = "CaptionBurner"
    private const val TIMEOUT_US = 10_000L

    /**
     * @param wordsJson JSON array of {"text","start","end"} (seconds).
     * @return absolute path of the captioned .mp4.
     */
    fun burn(mp4Path: String, wordsJson: String, outPath: String): String {
        val words = parseWords(wordsJson)
        Log.i(TAG, "burning ${words.size} words: $mp4Path -> $outPath")

        val extractor = MediaExtractor()
        extractor.setDataSource(mp4Path)
        val videoTrack = selectTrack(extractor, "video/")
            ?: throw IllegalArgumentException("no video track in $mp4Path")
        val srcFormat = extractor.getTrackFormat(videoTrack)
        val w = srcFormat.getInteger(MediaFormat.KEY_WIDTH)
        val h = srcFormat.getInteger(MediaFormat.KEY_HEIGHT)
        val frameRate = if (srcFormat.containsKey(MediaFormat.KEY_FRAME_RATE))
            srcFormat.getInteger(MediaFormat.KEY_FRAME_RATE) else 30
        val mime = srcFormat.getString(MediaFormat.KEY_MIME)!!

        // Audio passthrough, extracted up-front (short clips; ~1-2 MB).
        val audioSamples = extractAudioSamples(mp4Path)

        val reader = ImageReader.newInstance(w, h,
            android.graphics.ImageFormat.YUV_420_888, 3)
        val decoder = MediaCodec.createDecoderByType(mime)
        decoder.configure(srcFormat, reader.surface, null, 0)
        decoder.start()

        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val colorFormat = pickColorFormat(encoder)
        val encFormat = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
            setInteger(MediaFormat.KEY_BIT_RATE, (w * h * frameRate * 0.2).toInt())
            setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        encoder.configure(encFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        encoder.start()

        val muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var videoTrackIndex = -1
        var muxerStarted = false
        val muxedAudio = mutableListOf<Pair<ByteBuffer, MediaCodec.BufferInfo>>()

        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val argb = IntArray(w * h)
        val yuv = ByteArray(w * h * 3 / 2)
        val info = MediaCodec.BufferInfo()

        extractor.selectTrack(videoTrack)
        var decoderInputDone = false
        var decoderOutputDone = false
        var encoderOutputDone = false

        fun drainEncoder(endOfStream: Boolean) {
            while (true) {
                val outIndex = encoder.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER ->
                        if (endOfStream) break else return
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        if (muxerStarted) throw IllegalStateException("format changed twice")
                        videoTrackIndex = muxer.addTrack(encoder.outputFormat)
                        if (audioSamples.format != null) {
                            muxer.addTrack(audioSamples.format)
                        }
                        muxer.start()
                        muxerStarted = true
                        // Now flush the buffered audio, then keep writing video.
                        for ((buf, bi) in audioSamples.samples) {
                            muxer.writeSampleData(1, buf, bi)
                        }
                        audioSamples.samples.clear()
                    }
                    outIndex >= 0 -> {
                        if (!muxerStarted) throw IllegalStateException("no muxer track")
                        if (info.size > 0) {
                            val buf = encoder.getOutputBuffer(outIndex)!!
                            muxer.writeSampleData(videoTrackIndex, buf, info)
                        }
                        encoder.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            encoderOutputDone = true
                            break
                        }
                    }
                }
            }
        }

        try {
            while (!encoderOutputDone) {
                // Feed the decoder.
                if (!decoderInputDone) {
                    val inIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val buf = decoder.getInputBuffer(inIndex)!!
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            decoderInputDone = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, n,
                                extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                // Pull decoded frames, caption, and re-encode.
                var frame: android.media.Image? = null
                try {
                    frame = reader.acquireNextImage()
                } catch (_: IllegalStateException) { /* none yet */ }
                if (frame != null) {
                    try {
                        val tSec = frame.timestamp / 1_000_000_000.0
                        YuvConverter.toBitmap(frame, bitmap, argb)
                        KaraokeRenderer.draw(canvas, words, tSec, w, h)
                        ArgbToYuv.convert(bitmap, argb, yuv, colorFormat)
                        // Retry until the encoder takes the frame (never drop).
                        var queued = false
                        repeat(50) {
                            val inIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
                            if (inIndex >= 0) {
                                val buf = encoder.getInputBuffer(inIndex)!!
                                buf.clear()
                                buf.put(yuv)
                                encoder.queueInputBuffer(inIndex, 0, yuv.size,
                                    frame.timestamp / 1000, 0)
                                queued = true
                                return@repeat
                            }
                            drainEncoder(false)
                        }
                        if (!queued) throw IllegalStateException(
                            "encoder would not take input buffer")
                    } finally {
                        frame.close()
                    }
                    drainEncoder(false)
                } else if (decoderInputDone) {
                    // No more frames coming; check decoder EOS then end encode.
                    val outIndex = decoder.dequeueOutputBuffer(info, TIMEOUT_US)
                    if (outIndex >= 0) {
                        decoder.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            decoderOutputDone = true
                        }
                    }
                    if (decoderOutputDone) {
                        val inIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
                        if (inIndex >= 0) {
                            encoder.queueInputBuffer(inIndex, 0, 0, 0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        }
                        drainEncoder(true)
                    }
                }
            }
        } finally {
            try { muxer.stop() } catch (_: Throwable) {}
            muxer.release()
            try { decoder.stop() } catch (_: Throwable) {}
            decoder.release()
            try { encoder.stop() } catch (_: Throwable) {}
            encoder.release()
            reader.close()
            extractor.release()
            bitmap.recycle()
        }
        Log.i(TAG, "done: $outPath")
        return outPath
    }

    private data class AudioPassthrough(
        val format: MediaFormat?,
        val samples: MutableList<Pair<ByteBuffer, MediaCodec.BufferInfo>>,
    )

    private fun extractAudioSamples(mp4Path: String): AudioPassthrough {
        val samples = mutableListOf<Pair<ByteBuffer, MediaCodec.BufferInfo>>()
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(mp4Path)
            val track = selectTrack(extractor, "audio/") ?: return AudioPassthrough(null, samples)
            val format = extractor.getTrackFormat(track)
            extractor.selectTrack(track)
            val info = MediaCodec.BufferInfo()
            while (true) {
                val buf = ByteBuffer.allocate(256 * 1024)
                val n = extractor.readSampleData(buf, 0)
                if (n < 0) break
                info.set(0, n, extractor.sampleTime, extractor.sampleFlags)
                val copy = ByteBuffer.allocate(n)
                buf.position(0); buf.limit(n)
                copy.put(buf); copy.flip()
                val bi = MediaCodec.BufferInfo()
                bi.set(0, n, info.presentationTimeUs, info.flags)
                samples.add(copy to bi)
                extractor.advance()
            }
            return AudioPassthrough(format, samples)
        } finally {
            extractor.release()
        }
    }

    private fun selectTrack(extractor: MediaExtractor, prefix: String): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
            if (mime != null && mime.startsWith(prefix)) return i
        }
        return null
    }

    private fun pickColorFormat(encoder: MediaCodec): Int {
        val caps = encoder.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val recognized = caps.colorFormats.filter { it in
            listOf(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar) }
        return recognized.firstOrNull()
            ?: throw IllegalStateException("no YUV420 encoder color format")
    }

    private fun parseWords(json: String): List<KaraokeRenderer.Word> {
        // Minimal JSON parsing: [{"text":"...","start":0.0,"end":1.0}, ...]
        // (kept dependency-free; the Dart side produces this exact shape).
        val words = mutableListOf<KaraokeRenderer.Word>()
        val entry = Regex("""\{\s*"text"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"start"\s*:\s*([0-9.]+)\s*,\s*"end"\s*:\s*([0-9.]+)\s*\}""")
        for (m in entry.findAll(json)) {
            val text = m.groupValues[1]
                .replace("\\\"", "\"").replace("\\\\", "\\")
            words.add(KaraokeRenderer.Word(
                text, m.groupValues[2].toDouble(), m.groupValues[3].toDouble()))
        }
        return words
    }
}

/** ARGB Bitmap -> NV12 (semi-planar) or I420 (planar) for encoder input. */
object ArgbToYuv {
    fun convert(bitmap: Bitmap, argb: IntArray, yuv: ByteArray, colorFormat: Int) {
        val w = bitmap.width
        val h = bitmap.height
        bitmap.getPixels(argb, 0, w, 0, 0, w, h)
        val ySize = w * h
        var yi = 0
        if (colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) {
            var uvi = ySize
            for (j in 0 until h) {
                for (i in 0 until w) {
                    val p = argb[j * w + i]
                    val r = (p shr 16) and 0xff
                    val g = (p shr 8) and 0xff
                    val b = p and 0xff
                    yuv[yi++] = ((0.299 * r + 0.587 * g + 0.114 * b).toInt()
                        .coerceIn(0, 255)).toByte()
                    if (j % 2 == 0 && i % 2 == 0) {
                        yuv[uvi++] = ((-0.169 * r - 0.331 * g + 0.5 * b + 128).toInt()
                            .coerceIn(0, 255)).toByte()
                        yuv[uvi++] = ((0.5 * r - 0.419 * g - 0.081 * b + 128).toInt()
                            .coerceIn(0, 255)).toByte()
                    }
                }
            }
        } else {
            // I420: Y, then U plane, then V plane.
            var ui = ySize
            var vi = ySize + ySize / 4
            val uRow = ByteArray(w / 2 * h / 2)
            val vRow = ByteArray(w / 2 * h / 2)
            var uvi = 0
            for (j in 0 until h) {
                for (i in 0 until w) {
                    val p = argb[j * w + i]
                    val r = (p shr 16) and 0xff
                    val g = (p shr 8) and 0xff
                    val b = p and 0xff
                    yuv[yi++] = ((0.299 * r + 0.587 * g + 0.114 * b).toInt()
                        .coerceIn(0, 255)).toByte()
                    if (j % 2 == 0 && i % 2 == 0) {
                        uRow[uvi] = ((-0.169 * r - 0.331 * g + 0.5 * b + 128).toInt()
                            .coerceIn(0, 255)).toByte()
                        vRow[uvi] = ((0.5 * r - 0.419 * g - 0.081 * b + 128).toInt()
                            .coerceIn(0, 255)).toByte()
                        uvi++
                    }
                }
            }
            uRow.copyInto(yuv, ui)
            vRow.copyInto(yuv, vi)
        }
    }
}
