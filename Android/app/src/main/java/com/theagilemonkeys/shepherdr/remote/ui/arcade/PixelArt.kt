package com.theagilemonkeys.shepherdr.remote.ui.arcade

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.theagilemonkeys.shepherdr.remote.ui.Theme
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * Text in a 5×7 arcade font, drawn pixel by pixel; [scale] is a pixel's size in dp. Lowercase shows
 * as uppercase; a character the font lacks shows as a space.
 */
@Composable
fun PixelText(
    text: String,
    modifier: Modifier = Modifier,
    scale: Float = 2f,
    color: Color = Theme.phosphor,
    /** A darker copy one pixel down and right, as arcade titles have. */
    shadow: Color? = null,
) {
    val glyphs = remember(text) { text.uppercase().toList() }
    val offset = if (shadow == null) 0f else scale
    val width = PixelFont.width(text, scale) + offset
    Canvas(
        modifier
            .size(width.dp, (7 * scale + offset).dp)
            .semantics { contentDescription = text },
    ) {
        val pixel = scale.dp.toPx()
        val path = PixelFont.path(glyphs, pixel)
        if (shadow != null) translate(pixel, pixel) { drawPath(path, shadow) }
        drawPath(path, color)
    }
}

object PixelFont {
    fun width(text: String, scale: Float): Float = maxOf(0, text.length * 6 - 1) * scale

    fun path(glyphs: List<Char>, pixel: Float): Path {
        val path = Path()
        glyphs.forEachIndexed { index, character ->
            val rows = glyph[character] ?: return@forEachIndexed
            rows.forEachIndexed { y, row ->
                row.forEachIndexed { x, bit ->
                    if (bit == '#') path.addRect(Rect(Offset((index * 6 + x) * pixel, y * pixel), androidx.compose.ui.geometry.Size(pixel, pixel)))
                }
            }
        }
        return path
    }

    val glyph: Map<Char, List<String>> = mapOf(
        'A' to listOf(".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
        'B' to listOf("####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."),
        'C' to listOf(".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."),
        'D' to listOf("####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."),
        'E' to listOf("#####", "#....", "#....", "####.", "#....", "#....", "#####"),
        'F' to listOf("#####", "#....", "#....", "####.", "#....", "#....", "#...."),
        'G' to listOf(".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"),
        'H' to listOf("#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
        'I' to listOf(".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."),
        'J' to listOf("..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."),
        'K' to listOf("#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"),
        'L' to listOf("#....", "#....", "#....", "#....", "#....", "#....", "#####"),
        'M' to listOf("#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"),
        'N' to listOf("#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"),
        'O' to listOf(".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
        'P' to listOf("####.", "#...#", "#...#", "####.", "#....", "#....", "#...."),
        'Q' to listOf(".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"),
        'R' to listOf("####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"),
        'S' to listOf(".####", "#....", "#....", ".###.", "....#", "....#", "####."),
        'T' to listOf("#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."),
        'U' to listOf("#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
        'V' to listOf("#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."),
        'W' to listOf("#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."),
        'X' to listOf("#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"),
        'Y' to listOf("#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."),
        'Z' to listOf("#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"),
        '0' to listOf(".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."),
        '1' to listOf("..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."),
        '2' to listOf(".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"),
        '3' to listOf("#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."),
        '4' to listOf("...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."),
        '5' to listOf("#####", "#....", "####.", "....#", "....#", "#...#", ".###."),
        '6' to listOf("..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."),
        '7' to listOf("#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."),
        '8' to listOf(".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."),
        '9' to listOf(".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."),
        '!' to listOf("..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."),
        '?' to listOf(".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."),
        '.' to listOf(".....", ".....", ".....", ".....", ".....", ".....", "..#.."),
        ',' to listOf(".....", ".....", ".....", ".....", ".....", "..#..", ".#..."),
        ':' to listOf(".....", "..#..", ".....", ".....", ".....", "..#..", "....."),
        '-' to listOf(".....", ".....", ".....", ".###.", ".....", ".....", "....."),
        '+' to listOf(".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."),
        '×' to listOf(".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."),
        '/' to listOf("....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."),
        '\'' to listOf("..#..", "..#..", ".#...", ".....", ".....", ".....", "....."),
        '#' to listOf(".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."),
        '(' to listOf("...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."),
        ')' to listOf(".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."),
        '=' to listOf(".....", ".....", "#####", ".....", "#####", ".....", "....."),
        '_' to listOf(".....", ".....", ".....", ".....", ".....", ".....", "#####"),
        '★' to listOf("..#..", ".###.", "#####", ".###.", ".#.#.", "#...#", "....."),
        '▶' to listOf(".#...", ".##..", ".###.", ".####", ".###.", ".##..", ".#..."),
        '◀' to listOf("...#.", "..##.", ".###.", "####.", ".###.", "..##.", "...#."),
        '▲' to listOf(".....", ".....", "..#..", ".###.", "#####", ".....", "....."),
        '▼' to listOf(".....", ".....", "#####", ".###.", "..#..", ".....", "....."),
        '✓' to listOf(".....", ".....", "....#", "...#.", "#.#..", ".#...", "....."),
        ' ' to listOf(".....", ".....", ".....", ".....", ".....", ".....", "....."),
    )
}

/** A small picture drawn from rows of characters, each standing for a color in its palette; `.` is transparent. */
class Sprite(val rows: List<String>, val palette: Map<Char, Color>) {
    val width: Int = rows.maxOfOrNull { it.length } ?: 0
    val height: Int = rows.size

    fun draw(scope: DrawScope, origin: Offset, pixel: Float, flipped: Boolean = false) {
        val paths = mutableMapOf<Char, Path>()
        rows.forEachIndexed { y, row ->
            row.forEachIndexed { x, key ->
                if (key == '.') return@forEachIndexed
                val column = if (flipped) width - 1 - x else x
                paths.getOrPut(key) { Path() }.addRect(
                    Rect(Offset(origin.x + column * pixel, origin.y + y * pixel), androidx.compose.ui.geometry.Size(pixel, pixel)),
                )
            }
        }
        for ((key, path) in paths) palette[key]?.let { scope.drawPath(path, it) }
    }
}

/** Shepherdr's flock and its dog, in pixels. */
object Flock {
    /** A sheep facing right, in a color, with curls in its wool; the second frame moves its legs. */
    fun sheep(wool: Color, step: Boolean = false) = Sprite(
        listOf(
            "...WW.WW.WW.....",
            "..WWWWWWWWWWW...",
            ".WWCWWWWCWWWWKK.",
            "WWWWWWCWWWWWKFFF",
            "WCWWWWWWWCWWKFEF",
            "WWWWCWWWWWWW.FFF",
            ".WWWWWWCWWWW..F.",
            "..WWWWWWWWWW....",
            "...K.K....K.K...",
            if (step) "..K...K..K...K.." else "...K.K....K.K...",
        ),
        mapOf(
            'W' to wool, 'C' to wool.copy(alpha = wool.alpha * 0.62f), 'F' to wool.copy(alpha = wool.alpha * 0.42f),
            'K' to wool.copy(alpha = wool.alpha * 0.3f), 'E' to Theme.text,
        ),
    )

    /** Shepherdr's dog running right, as the app's icon paints it; the second frame gathers its legs. */
    fun dog(step: Boolean = false): Sprite {
        val legs = if (step) {
            listOf("....TT.T...T.TT.....", "....T..T...T..T.....", "...TT..TT.TT..TT....")
        } else {
            listOf("...TT.T.....T.TT....", "..TT..T.....T...TT..", ".TT...TT...TT....TT.")
        }
        return Sprite(
            listOf(
                "..............K..K..",
                "..............KK.KK.",
                "..............KTTTK.",
                ".............KTTETTT",
                ".............KTTTTTN",
                "K...KKKKKKKKKKTTTP..",
                "KK.KKKKKKKKKKKTT....",
                ".KKTKKKKKKKKKTTT....",
                "...TTTTTTTTTTTT.....",
            ) + legs,
            mapOf(
                'K' to Color(0xFF5A3A1E), 'T' to Color(0xFFD9A050), 'N' to Color(0xFF1A1A1A),
                'E' to Theme.phosphor, 'P' to Color(0xFFF07A8A),
            ),
        )
    }
}

/** A sprite as a view; [scale] is a pixel's size in dp. */
@Composable
fun SpriteView(sprite: Sprite, modifier: Modifier = Modifier, scale: Float = 3f) {
    Canvas(modifier.size((sprite.width * scale).dp, (sprite.height * scale).dp)) {
        sprite.draw(this, Offset.Zero, scale.dp.toPx())
    }
}

/** A counter that goes up every [periodMillis], for blinking and other steps in time. */
@Composable
fun rememberTick(periodMillis: Long): Long {
    var tick by remember { mutableLongStateOf(System.currentTimeMillis() / periodMillis) }
    LaunchedEffect(periodMillis) {
        while (isActive) {
            val now = System.currentTimeMillis()
            delay(periodMillis - now % periodMillis)
            tick = System.currentTimeMillis() / periodMillis
        }
    }
    return tick
}

/** The time now, updated every frame while shown, for animations. */
@Composable
fun rememberFrameTime(): Long {
    var time by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (isActive) {
            androidx.compose.runtime.withFrameMillis { time = System.currentTimeMillis() }
        }
    }
    return time
}

/** Blinks what it wraps, twice a second, as arcade prompts do. */
@Composable
fun Blinking(periodMillis: Long = 500, content: @Composable () -> Unit) {
    val tick = rememberTick(periodMillis)
    Box(Modifier.alpha(if (tick % 2 == 0L) 1f else 0.12f)) { content() }
}
