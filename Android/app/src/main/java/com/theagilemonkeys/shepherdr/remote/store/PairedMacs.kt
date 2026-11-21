package com.theagilemonkeys.shepherdr.remote.store

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * A Mac this phone paired with: where to find it and which certificate is its own. Its token
 * lives in [TokenVault], encrypted with a key that never leaves this device.
 */
@Serializable
data class PairedMac(
    val deviceID: String,
    val name: String,
    val hosts: List<String>,
    val port: Int,
    val fingerprint: String,
) {
    val id: String get() = deviceID
}

class PairedMacs(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("shepherdr", Context.MODE_PRIVATE)
    private val vault = TokenVault(context)
    private val serializer = ListSerializer(PairedMac.serializer())

    fun load(): List<PairedMac> = try {
        prefs.getString(KEY, null)?.let { Json.decodeFromString(serializer, it) } ?: emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    fun save(macs: List<PairedMac>) {
        prefs.edit().putString(KEY, Json.encodeToString(serializer, macs)).apply()
    }

    fun token(mac: PairedMac): String? = vault.read(mac.deviceID)

    /** Keeps a paired Mac; false when the vault refused its token, so it can't be kept. */
    fun add(mac: PairedMac, token: String): Boolean {
        if (!vault.write(token, mac.deviceID)) return false
        save(load().filter { it.deviceID != mac.deviceID && it.fingerprint != mac.fingerprint } + mac)
        return true
    }

    fun remove(mac: PairedMac) {
        vault.delete(mac.deviceID)
        save(load().filter { it.deviceID != mac.deviceID })
    }

    private companion object {
        const val KEY = "pairedMacs"
    }
}

/** Tokens, encrypted with AES-GCM under an Android Keystore key, as iOS keeps them in the keychain. */
class TokenVault(context: Context) {
    private val prefs = context.getSharedPreferences("shepherdr.tokens", Context.MODE_PRIVATE)

    fun write(value: String, account: String): Boolean = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(account, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()
    } catch (_: Exception) {
        false
    }

    fun read(account: String): String? = try {
        prefs.getString(account, null)?.let { stored ->
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_SIZE))
            String(cipher.doFinal(sealed, IV_SIZE, sealed.size - IV_SIZE), Charsets.UTF_8)
        }
    } catch (_: Exception) {
        null
    }

    fun delete(account: String) {
        prefs.edit().remove(account).apply()
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "shepherdr.relay.tokens"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
    }
}
