package com.theagilemonkeys.shepherdr.remote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.theagilemonkeys.shepherdr.remote.protocol.QueueRow
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteSessionID

/** The screens on top of the queue, as iOS's navigation stack holds them. */
sealed interface Screen {
    /** A session, as the queue showed it when you opened it. Two are the same screen when they show the same session. */
    class Session(val row: QueueRow, val session: RemoteSessionID) : Screen {
        override fun equals(other: Any?) = other is Session && other.session == session
        override fun hashCode() = session.hashCode()
    }

    data object Compass : Screen
}

/** Where the app is, and what a link or a launch asked for. */
class Navigator {
    val stack = mutableStateListOf<Screen>()
    /** Start a game of herd mode as soon as the queue has sessions astray; for tests. */
    var startsHerd by mutableStateOf(false)

    fun push(screen: Screen) {
        if (stack.lastOrNull() != screen) stack.add(screen)
    }

    fun pop() {
        if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex)
    }

    fun reset(vararg screens: Screen) {
        stack.clear()
        stack.addAll(screens)
    }
}

/** A screen's bar: back, a title in the middle and actions at the end. */
@Composable
fun ScreenBar(onBack: () -> Unit, actions: @Composable RowScope.() -> Unit = {}, title: @Composable () -> Unit) {
    Box(Modifier.fillMaxWidth().height(52.dp).background(Theme.background)) {
        IconButton(onClick = onBack, modifier = Modifier.align(Alignment.CenterStart)) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Theme.phosphor)
        }
        Box(Modifier.align(Alignment.Center).padding(horizontal = 96.dp)) { title() }
        Row(Modifier.align(Alignment.CenterEnd), verticalAlignment = Alignment.CenterVertically, content = actions)
    }
}

/** A small rounded tag, as the queue's counts show. */
@Composable
fun Chip(text: String, color: Color) {
    Text(
        text, style = Theme.mono(11f), color = color, maxLines = 1,
        modifier = Modifier
            .border(1.dp, color.copy(alpha = 0.4f), RoundedCornerShape(50))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

/** A bordered button in the console's style. */
@Composable
fun ConsoleButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    color: Color = Theme.dim,
    filled: Boolean = false,
    enabled: Boolean = true,
    leading: (@Composable () -> Unit)? = null,
) {
    val tint = if (enabled) color else Theme.faint
    Row(
        modifier
            .background(if (filled && enabled) tint else Color.Transparent, RoundedCornerShape(8.dp))
            .border(1.dp, tint.copy(alpha = if (filled) 1f else 0.5f), RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        leading?.invoke()
        Text(text, style = Theme.mono(12f, FontWeight.SemiBold), color = if (filled && enabled) Theme.background else tint)
    }
}

/** A section's heading in a sheet. */
@Composable
fun SectionTitle(text: String) {
    Column(Modifier.padding(top = 18.dp, bottom = 6.dp)) {
        Text(text.uppercase(), style = Theme.mono(10.5f, FontWeight.SemiBold, 2.sp), color = Theme.faint)
    }
}
