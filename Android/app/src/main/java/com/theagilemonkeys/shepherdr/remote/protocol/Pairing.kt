package com.theagilemonkeys.shepherdr.remote.protocol

import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.util.Base64

/**
 * What a pairing QR code carries: where the Mac listens, which certificate is its own, and a code
 * that can be used once.
 */
data class PairingInvite(
    val macName: String,
    /** Addresses to try in order, such as the Mac's Tailscale addresses. */
    val hosts: List<String>,
    val port: Int,
    /** The SHA-256 of the certificate's public key: the phone trusts nothing else. */
    val fingerprint: String,
    val code: String,
) {
    val url: String
        get() = "$SCHEME://pair?" + listOf(
            "n" to macName, "h" to hosts.joinToString(","), "p" to port.toString(), "f" to fingerprint, "c" to code,
        ).joinToString("&") { (name, value) -> "$name=${UrlParts.encode(value)}" }

    companion object {
        const val SCHEME = "shepherdr-remote"

        fun parse(string: String): PairingInvite? {
            val url = UrlParts.parse(string.trim()) ?: return null
            if (url.scheme != SCHEME || url.host != "pair") return null
            val items = url.query
            val hosts = (items["h"] ?: "").split(",").filter { it.isNotEmpty() }
            val name = items["n"] ?: return null
            val port = items["p"]?.toIntOrNull() ?: return null
            val fingerprint = items["f"] ?: return null
            val code = items["c"] ?: return null
            if (hosts.isEmpty() || port !in 1..65535 || fingerprint.isEmpty() || code.isEmpty()) return null
            return PairingInvite(name, hosts, port, fingerprint, code)
        }
    }
}

/** `shepherdr-remote://session?m=<machine>&t=<terminal>` opens that session. */
object SessionLink {
    fun session(from: String): RemoteSessionID? {
        val url = UrlParts.parse(from.trim()) ?: return null
        if (url.scheme != PairingInvite.SCHEME || url.host != "session") return null
        val machine = url.query["m"] ?: return null
        val terminal = url.query["t"] ?: return null
        return RemoteSessionID(machine, terminal)
    }
}

object RemoteCrypto {
    /**
     * The fingerprint both sides compare: SHA-256 of the public key's external representation
     * (an uncompressed P-256 point), base64url without padding.
     */
    fun fingerprint(publicKey: ByteArray): String =
        base64URL(MessageDigest.getInstance("SHA-256").digest(publicKey))

    /** The uncompressed point (`04 ‖ X ‖ Y`) of an EC public key, as Apple's Security framework exports it. */
    fun uncompressedPoint(key: ECPublicKey): ByteArray {
        val size = (key.params.curve.field.fieldSize + 7) / 8
        return byteArrayOf(4) + fixed(key.w.affineX, size) + fixed(key.w.affineY, size)
    }

    /** 32 random bytes, base64url: tokens and pairing codes. */
    fun randomToken(): String = base64URL(ByteArray(32).also { SecureRandom().nextBytes(it) })

    fun base64URL(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    private fun fixed(value: BigInteger, size: Int): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == size -> bytes
            bytes.size > size -> bytes.copyOfRange(bytes.size - size, bytes.size)
            else -> ByteArray(size - bytes.size) + bytes
        }
    }
}

/**
 * The parts of a `scheme://host?query` link, read as Foundation's `URLComponents` reads them:
 * percent escapes decode, and `+` stays a plus.
 */
internal data class UrlParts(val scheme: String, val host: String, val query: Map<String, String>) {
    companion object {
        fun parse(string: String): UrlParts? {
            val schemeEnd = string.indexOf("://")
            if (schemeEnd <= 0) return null
            val scheme = string.substring(0, schemeEnd).lowercase()
            val rest = string.substring(schemeEnd + 3)
            val hostEnd = rest.indexOfAny(charArrayOf('/', '?', '#')).let { if (it < 0) rest.length else it }
            val host = rest.substring(0, hostEnd)
            val queryStart = rest.indexOf('?')
            val query = LinkedHashMap<String, String>()
            if (queryStart >= 0) {
                val raw = rest.substring(queryStart + 1).substringBefore('#')
                for (item in raw.split("&")) {
                    if (item.isEmpty()) continue
                    val name = decode(item.substringBefore('=')) ?: return null
                    val value = if (item.contains('=')) decode(item.substringAfter('=')) ?: return null else ""
                    // The first of a repeated name wins.
                    query.putIfAbsent(name, value)
                }
            }
            return UrlParts(scheme, host, query)
        }

        fun encode(value: String): String {
            val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,:@!$'()*+;/?"
            val out = StringBuilder()
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val char = (byte.toInt() and 0xFF).toChar()
                if (byte >= 0 && allowed.indexOf(char) >= 0) out.append(char)
                else out.append('%').append("%02X".format(byte.toInt() and 0xFF))
            }
            return out.toString()
        }

        private fun decode(text: String): String? {
            if (!text.contains('%')) return text
            val bytes = java.io.ByteArrayOutputStream()
            var index = 0
            while (index < text.length) {
                val char = text[index]
                if (char == '%') {
                    if (index + 2 >= text.length) return null
                    val value = text.substring(index + 1, index + 3).toIntOrNull(16) ?: return null
                    bytes.write(value)
                    index += 3
                } else {
                    bytes.write(char.toString().toByteArray(Charsets.UTF_8))
                    index += 1
                }
            }
            return bytes.toString(Charsets.UTF_8.name())
        }
    }
}
