package com.theagilemonkeys.shepherdr.remote.relay

import com.theagilemonkeys.shepherdr.remote.protocol.RemoteCrypto
import okhttp3.ConnectionSpec
import okhttp3.OkHttpClient
import okhttp3.TlsVersion
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.X509TrustManager

/**
 * The WebSocket under [RelayClient]: TLS 1.3 that trusts exactly the Mac's own certificate, the key
 * whose fingerprint the pairing code carried. The Mac's certificate is self-signed and names the
 * Mac, not the address the phone dials, so the pin replaces both the chain and the host name checks.
 */
object RelaySocket {
    /** A client for one attempt; [refusal] says why the Mac's certificate wasn't trusted, if it wasn't. */
    fun client(pinning: String, refusal: AtomicReference<String?>): OkHttpClient {
        val trust = PinnedTrustManager(pinning, refusal)
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
        val spec = ConnectionSpec.Builder(ConnectionSpec.MODERN_TLS).tlsVersions(TlsVersion.TLS_1_3).build()
        return OkHttpClient.Builder()
            .sslSocketFactory(tls.socketFactory, trust)
            .hostnameVerifier { _, _ -> true }
            .connectionSpecs(listOf(spec))
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            // The Mac answers WebSocket pings itself: a connection that stops answering is dropped.
            .pingInterval(30, TimeUnit.SECONDS)
            .build()
    }

    fun describe(error: Throwable?): String = when (error) {
        null -> "the connection closed"
        is ConnectException -> "nothing listens on that port"
        is SocketTimeoutException -> "the connection timed out"
        is NoRouteToHostException -> "there is no route to it"
        is UnknownHostException -> "its address couldn't be found"
        is SSLException -> "TLS failed, ${error.message ?: error.javaClass.simpleName}"
        else -> error.message ?: error.javaClass.simpleName
    }

    private class PinnedTrustManager(
        private val fingerprint: String,
        private val refusal: AtomicReference<String?>,
    ) : X509TrustManager {
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val key = chain?.firstOrNull()?.publicKey as? ECPublicKey
            if (key == null) {
                refusal.set("its certificate couldn't be read")
                throw CertificateException("The Mac's certificate couldn't be read.")
            }
            if (RemoteCrypto.fingerprint(RemoteCrypto.uncompressedPoint(key)) != fingerprint) {
                refusal.set("it showed a certificate other than the one it paired with")
                throw CertificateException("The Mac showed a certificate other than the one it paired with.")
            }
        }

        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
            throw CertificateException("This phone doesn't take connections.")

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
