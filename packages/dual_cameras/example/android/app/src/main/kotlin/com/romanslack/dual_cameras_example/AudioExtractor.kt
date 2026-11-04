package com.romanslack.dual_cameras_example

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Extracts the audio track of an .mp4 and writes it as a 16 kHz mono 16-bit
 * WAV — the exact input sherpa-onnx Whisper expects. Used by the
 * auto-captions post-processing path (example app only).
 */
object AudioExtractor {
    const val TARGET_SAMPLE_RATE = 16000

    fun extractToWav(mp4Path: String, wavPath: String) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(mp4Path)
            val track = selectTrack(extractor, "audio/")
                ?: throw IllegalArgumentException("no audio track in $mp4Path")
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalArgumentException("audio track has no mime")
            val srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            extractor.selectTrack(track)
            val decoder = MediaCodec.createDecoderByType(mime)
            try {
                decoder.configure(format, null, null, 0)
                decoder.start()
                val pcm = decodeAll(decoder, extractor)
                val mono16k = resampleToMono16k(pcm, srcRate, srcChannels)
                writeWav(File(wavPath), mono16k)
            } finally {
                try { decoder.stop() } catch (_: Throwable) {}
                decoder.release()
            }
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

    /** Decode the whole selected track into interleaved 16-bit PCM. */
    private fun decodeAll(decoder: MediaCodec, extractor: MediaExtractor): ByteArray {
        val out = mutableListOf<Byte>()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        while (!outputDone) {
            if (!inputDone) {
                val inIndex = decoder.dequeueInputBuffer(10_000)
                if (inIndex >= 0) {
                    val buf = decoder.getInputBuffer(inIndex)!!
                    val n = extractor.readSampleData(buf, 0)
                    if (n < 0) {
                        decoder.queueInputBuffer(inIndex, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        decoder.queueInputBuffer(inIndex, 0, n,
                            extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            val outIndex = decoder.dequeueOutputBuffer(info, 10_000)
            when {
                outIndex >= 0 -> {
                    if (info.size > 0) {
                        val buf = decoder.getOutputBuffer(outIndex)!!
                        val chunk = ByteArray(info.size)
                        buf.position(info.offset)
                        buf.get(chunk)
                        chunk.forEach { out.add(it) }
                    }
                    decoder.releaseOutputBuffer(outIndex, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                    }
                }
                outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {}
            }
        }
        return out.toByteArray()
    }

    /** Downmix to mono and linearly resample to 16 kHz. */
    private fun resampleToMono16k(
        pcm: ByteArray, srcRate: Int, srcChannels: Int,
    ): ShortArray {
        if (pcm.isEmpty()) return ShortArray(0)
        val src = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val srcFrames = src.remaining() / srcChannels
        // Downmix: average channels.
        val mono = FloatArray(srcFrames)
        for (i in 0 until srcFrames) {
            var sum = 0f
            for (c in 0 until srcChannels) sum += src.get(i * srcChannels + c)
            mono[i] = sum / srcChannels
        }
        if (srcRate == TARGET_SAMPLE_RATE) {
            return ShortArray(mono.size) { mono[it].toInt().coerceIn(-32768, 32767).toShort() }
        }
        val ratio = TARGET_SAMPLE_RATE.toDouble() / srcRate
        val dstFrames = (srcFrames * ratio).toInt()
        return ShortArray(dstFrames) { i ->
            val pos = i / ratio
            val i0 = pos.toInt().coerceIn(0, srcFrames - 1)
            val i1 = (i0 + 1).coerceIn(0, srcFrames - 1)
            val frac = (pos - i0).toFloat()
            val v = mono[i0] * (1 - frac) + mono[i1] * frac
            v.toInt().coerceIn(-32768, 32767).toShort()
        }
    }

    private fun writeWav(file: File, pcm: ShortArray) {
        FileOutputStream(file).use { fos ->
            val dataSize = pcm.size * 2
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray())
            header.putInt(36 + dataSize)
            header.put("WAVE".toByteArray())
            header.put("fmt ".toByteArray())
            header.putInt(16) // PCM chunk size
            header.putShort(1) // PCM format
            header.putShort(1) // mono
            header.putInt(TARGET_SAMPLE_RATE)
            header.putInt(TARGET_SAMPLE_RATE * 2) // byte rate
            header.putShort(2) // block align
            header.putShort(16) // bits per sample
            header.put("data".toByteArray())
            header.putInt(dataSize)
            fos.write(header.array())
            val bytes = ByteBuffer.allocate(dataSize).order(ByteOrder.LITTLE_ENDIAN)
            bytes.asShortBuffer().put(pcm)
            fos.write(bytes.array())
        }
    }
}
