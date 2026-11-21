package com.theagilemonkeys.shepherdr.remote.ui

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.theagilemonkeys.shepherdr.remote.protocol.PairingInvite
import com.theagilemonkeys.shepherdr.remote.relay.RelayClient

/** Pairing: scan the code Settings → Remote shows on the Mac, or paste its link. */
@Composable
fun PairScreen(client: RelayClient, onPaired: (() -> Unit)? = null) {
    val context = LocalContext.current
    var problem by remember { mutableStateOf<String?>(null) }
    val phase = client.phase

    fun use(text: String) {
        val invite = PairingInvite.parse(text)
        if (invite == null) {
            problem = "That isn't a Shepherdr pairing code."
            return
        }
        problem = null
        client.pair(invite)
    }

    // Once paired, a pairing opened from Settings closes.
    var pairingStarted by remember { mutableStateOf(false) }
    LaunchedEffect(phase, client.mac?.id) {
        if (phase == RelayClient.Phase.Connecting) pairingStarted = true
        if (onPaired != null && pairingStarted && phase == RelayClient.Phase.Connected) onPaired()
    }

    Column(
        Modifier.fillMaxSize().background(Theme.background).padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp, Alignment.CenterVertically),
    ) {
        Text("SHEPHERDR", style = Theme.mono(13f, FontWeight.SemiBold, 3.sp), color = Theme.faint)
        Text("Remote", style = Theme.mono(40f, FontWeight.Medium), color = Theme.phosphor)
        Text(
            "Your Mac's queue, terminals and prompts, through Tailscale. On the Mac, open Shepherdr → Settings → Remote, " +
                "turn it on and choose Pair iPhone. The same code pairs this phone.",
            style = Theme.mono(13f), color = Theme.dim,
        )
        if (phase == RelayClient.Phase.Connecting) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(18.dp), color = Theme.phosphor, strokeWidth = 2.dp)
                Text("Pairing…", style = Theme.mono(13f), color = Theme.dim)
            }
        }
        if (phase is RelayClient.Phase.Failed) Text(phase.message, style = Theme.mono(13f), color = Theme.amber)
        problem?.let { Text(it, style = Theme.mono(13f), color = Theme.amber) }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ConsoleButton(
                "Scan Pairing Code", onClick = { scan(context, ::use) { problem = it } },
                modifier = Modifier.fillMaxWidth(), color = Theme.phosphor, filled = true,
                leading = { Icon(Icons.Filled.QrCodeScanner, contentDescription = null, tint = Theme.background, modifier = Modifier.size(18.dp)) },
            )
            ConsoleButton(
                "Paste Pairing Link",
                onClick = {
                    val text = context.getSystemService(ClipboardManager::class.java)?.primaryClip
                        ?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
                    if (text.isNullOrBlank()) problem = "The clipboard is empty. On the Mac, choose Copy Link in the pairing window."
                    else use(text)
                },
                modifier = Modifier.fillMaxWidth(), color = Theme.phosphor,
                leading = { Icon(Icons.Filled.ContentPaste, contentDescription = null, tint = Theme.phosphor, modifier = Modifier.size(18.dp)) },
            )
        }
        Spacer(Modifier.size(1.dp))
    }
}

/** Google's code scanner: the camera, looking for a QR code, without this app holding the camera. */
private fun scan(context: Context, found: (String) -> Unit, failed: (String) -> Unit) {
    val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    GmsBarcodeScanning.getClient(context, options).startScan()
        .addOnSuccessListener { barcode ->
            val text = barcode.rawValue
            if (text != null && text.startsWith(PairingInvite.SCHEME)) found(text)
            else failed("That isn't a Shepherdr pairing code.")
        }
        .addOnFailureListener { failed("The scanner didn't start (${it.message}). Paste the pairing link instead.") }
}
