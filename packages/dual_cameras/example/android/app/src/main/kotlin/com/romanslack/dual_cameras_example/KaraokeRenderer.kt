package com.romanslack.dual_cameras_example

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface

/**
 * Draws Hormozi/Reels-style karaoke captions: a few words on screen,
 * the currently-spoken word highlighted. Words are grouped into phrases of
 * [WORDS_PER_PHRASE]; the phrase containing the active word is shown.
 *
 * All text is uppercased, bold, white with a black stroke; the active word
 * pops in [HIGHLIGHT].
 */
object KaraokeRenderer {
    private const val WORDS_PER_PHRASE = 4
    private val HIGHLIGHT = Color.parseColor("#FFD60A")
    private const val TEXT = Color.WHITE
    private const val STROKE = Color.BLACK

    data class Word(val text: String, val start: Double, val end: Double)

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textAlign = Paint.Align.LEFT
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textAlign = Paint.Align.LEFT
        style = Paint.Style.STROKE
    }

    /** Draw the caption for time [tSec] onto [canvas] (already sized w×h). */
    fun draw(canvas: Canvas, words: List<Word>, tSec: Double, w: Int, h: Int) {
        if (words.isEmpty()) return
        val active = words.indexOfFirst { tSec < it.end }
            .let { if (it < 0) words.size - 1 else it }
        if (tSec < words.first().start - 0.5) return // nothing spoken yet

        val phraseStart = (active / WORDS_PER_PHRASE) * WORDS_PER_PHRASE
        val phraseEnd = (phraseStart + WORDS_PER_PHRASE).coerceAtMost(words.size)
        val phrase = words.subList(phraseStart, phraseEnd)
        val activeInPhrase = active - phraseStart
        val texts = phrase.map { it.text.uppercase() }

        // Fit: shrink until the phrase fits 92% of the width.
        var textSize = h * 0.055f
        fill.textSize = textSize
        while (textSize > h * 0.02f &&
            fill.measureText(texts.joinToString(" ")) > w * 0.92f
        ) {
            textSize *= 0.94f
            fill.textSize = textSize
        }
        stroke.textSize = textSize
        stroke.strokeWidth = textSize / 10f

        val spaceW = fill.measureText(" ")
        val widths = texts.map { fill.measureText(it) }
        val totalW = widths.sum() + spaceW * (texts.size - 1)
        var x = (w - totalW) / 2f
        val y = h * 0.74f // lower-middle, clear of the selfie inset

        texts.forEachIndexed { i, text ->
            val color = if (i == activeInPhrase) HIGHLIGHT else TEXT
            stroke.color = STROKE
            canvas.drawText(text, x, y, stroke)
            fill.color = color
            canvas.drawText(text, x, y, fill)
            x += widths[i] + spaceW
        }
    }
}
