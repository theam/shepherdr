package com.theagilemonkeys.shepherdr.remote.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import com.theagilemonkeys.shepherdr.remote.R

/** Shepherdr's phosphor console, as the Mac app paints it (App/Theme.swift). */
object Theme {
    val background = Color(0xFF090C0A)
    val panel = Color(0xFF0E1310)
    val raised = Color(0xFF141B17)
    val line = Color(0xFF1F2B25)
    val text = Color(0xFFD9E7DE)
    val dim = Color(0xFF7E9488)
    val faint = Color(0xFF4B5E53)
    val phosphor = Color(0xFF4DFFA0)
    val amber = Color(0xFFFFB547)
    val cyan = Color(0xFF5CD6FF)
    val red = Color(0xFFFF5F57)
    val lilac = Color(0xFFD77CFF)

    val fira = FontFamily(
        Font(R.font.firacode_regular, FontWeight.Normal),
        Font(R.font.firacode_medium, FontWeight.Medium),
        Font(R.font.firacode_semibold, FontWeight.SemiBold),
        Font(R.font.firacode_bold, FontWeight.Bold),
    )

    fun mono(size: Float, weight: FontWeight = FontWeight.Normal, tracking: TextUnit = TextUnit.Unspecified): TextStyle =
        TextStyle(fontFamily = fira, fontSize = size.sp, fontWeight = weight, letterSpacing = tracking)

    /** The color a session's status shows in, as the Mac's queue does. */
    fun color(status: String?): Color = when (status) {
        "needsYou" -> amber
        "working", "running" -> phosphor
        "waiting" -> lilac
        "done", "finished" -> cyan
        "stale" -> red
        else -> dim
    }

    fun label(status: String?): String = when (status) {
        "needsYou" -> "NEEDS YOU"
        "waiting" -> "ON HOLD"
        null -> ""
        else -> status.uppercase()
    }
}

private val scheme = darkColorScheme(
    primary = Theme.phosphor,
    onPrimary = Theme.background,
    secondary = Theme.amber,
    onSecondary = Theme.background,
    tertiary = Theme.cyan,
    background = Theme.background,
    onBackground = Theme.text,
    surface = Theme.panel,
    onSurface = Theme.text,
    surfaceVariant = Theme.raised,
    onSurfaceVariant = Theme.dim,
    surfaceContainer = Theme.panel,
    surfaceContainerHigh = Theme.raised,
    surfaceContainerHighest = Theme.raised,
    surfaceContainerLow = Theme.panel,
    outline = Theme.line,
    outlineVariant = Theme.line,
    error = Theme.red,
)

@Composable
fun ShepherdrTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}
