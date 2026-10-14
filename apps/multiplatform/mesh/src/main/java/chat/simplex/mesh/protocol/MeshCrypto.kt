package chat.simplex.mesh.protocol

import java.math.BigInteger
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Crypto primitives for ChatFort's crowd mesh. Platform JCA only:
 * P-256 keys, ECDSA-SHA256 signatures, ECDH, HKDF-SHA256 (RFC 5869) and AES-256-GCM.
 */
object MeshCrypto {
    const val PUBLIC_KEY_SIZE = 65
    const val PEER_ID_SIZE = 8
    const val NONCE_SIZE = 12
    const val KEY_SIZE = 32
    private const val GCM_TAG_BITS = 128

    private val random = SecureRandom()

    private val curve: ECParameterSpec by lazy { (generateKeyPair().public as ECPublicKey).params }

    fun generateKeyPair(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()

    /** Uncompressed SEC1 point: 0x04 || X || Y. */
    fun encodePublicKey(key: PublicKey): ByteArray {
        val w = (key as ECPublicKey).w
        return byteArrayOf(0x04) + fixed32(w.affineX) + fixed32(w.affineY)
    }

    /** Returns null unless [bytes] is a valid P-256 point (protects ECDH from invalid-curve points). */
    fun decodePublicKey(bytes: ByteArray): PublicKey? {
        if (bytes.size != PUBLIC_KEY_SIZE || bytes[0] != 0x04.toByte()) return null
        val x = BigInteger(1, bytes.copyOfRange(1, 33))
        val y = BigInteger(1, bytes.copyOfRange(33, 65))
        if (!isOnCurve(x, y)) return null
        return try {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), curve))
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    fun decodePrivateKey(pkcs8: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(pkcs8))

    fun peerId(publicKey: ByteArray): ByteArray = sha256(publicKey).copyOf(PEER_ID_SIZE)

    fun sign(privateKey: PrivateKey, data: ByteArray): ByteArray =
        Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey)
            update(data)
            sign()
        }

    fun verify(publicKey: PublicKey, data: ByteArray, signature: ByteArray): Boolean = try {
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(publicKey)
            update(data)
            verify(signature)
        }
    } catch (_: GeneralSecurityException) {
        false
    } catch (_: IllegalArgumentException) {
        false
    }

    fun ecdh(privateKey: PrivateKey, publicKey: PublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(privateKey)
            doPhase(publicKey, true)
            generateSecret()
        }

    /** HKDF-SHA256 (RFC 5869). A null or empty salt means HashLen zero bytes. */
    fun hkdf(ikm: ByteArray, salt: ByteArray?, info: ByteArray, length: Int): ByteArray {
        require(length in 1..(255 * 32))
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt == null || salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var block = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            mac.update(block)
            mac.update(info)
            mac.update(counter.toByte())
            block = mac.doFinal()
            val n = minOf(block.size, length - pos)
            System.arraycopy(block, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }

    fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        parts.forEach { mac.update(it) }
        return mac.doFinal()
    }

    /** AES-256-GCM. Output: nonce || ciphertext+tag. */
    fun seal(key: ByteArray, plaintext: ByteArray, aad: ByteArray): ByteArray = sealWithNonce(key, plaintext, aad, randomBytes(NONCE_SIZE))

    /** [seal] with a caller-chosen nonce. Only for test vectors: a nonce must never repeat under one key. */
    internal fun sealWithNonce(key: ByteArray, plaintext: ByteArray, aad: ByteArray, nonce: ByteArray): ByteArray {
        require(nonce.size == NONCE_SIZE)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        cipher.updateAAD(aad)
        return nonce + cipher.doFinal(plaintext)
    }

    /** Opens [seal] output; null if the key is wrong or anything was tampered with. */
    fun open(key: ByteArray, sealed: ByteArray, aad: ByteArray): ByteArray? {
        if (sealed.size < NONCE_SIZE + GCM_TAG_BITS / 8) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, sealed, 0, NONCE_SIZE))
            cipher.updateAAD(aad)
            cipher.doFinal(sealed, NONCE_SIZE, sealed.size - NONCE_SIZE)
        } catch (_: AEADBadTagException) {
            null
        } catch (_: GeneralSecurityException) {
            null
        }
    }

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    /** Cryptographically random Int (Bluetooth tokens must not be predictable). */
    fun randomInt(): Int = random.nextInt()

    /** A P-256 key pair from a fixed private scalar. Only for test vectors. */
    internal fun keyPairFromScalar(scalar: BigInteger): KeyPair {
        val priv = KeyFactory.getInstance("EC").generatePrivate(java.security.spec.ECPrivateKeySpec(scalar, curve))
        val g = curve.generator
        val pubPoint = multiply(ECPoint(g.affineX, g.affineY), scalar)
        val pub = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(pubPoint, curve))
        return KeyPair(pub, priv)
    }

    /** P-256 group order. */
    val curveOrder: BigInteger get() = curve.order

    // Affine double-and-add, only used by [keyPairFromScalar] for test vectors.
    private fun multiply(p: ECPoint, k: BigInteger): ECPoint {
        var result: ECPoint = ECPoint.POINT_INFINITY
        var addend = p
        for (i in 0 until k.bitLength()) {
            if (k.testBit(i)) result = add(result, addend)
            addend = add(addend, addend)
        }
        return result
    }

    private fun add(a: ECPoint, b: ECPoint): ECPoint {
        if (a == ECPoint.POINT_INFINITY) return b
        if (b == ECPoint.POINT_INFINITY) return a
        val p = (curve.curve.field as ECFieldFp).p
        val lambda = if (a.affineX == b.affineX) {
            if (a.affineY.add(b.affineY).mod(p).signum() == 0) return ECPoint.POINT_INFINITY
            a.affineX.pow(2).multiply(BigInteger.valueOf(3)).add(curve.curve.a)
                .multiply(a.affineY.shiftLeft(1).modInverse(p)).mod(p)
        } else {
            b.affineY.subtract(a.affineY).multiply(b.affineX.subtract(a.affineX).modInverse(p)).mod(p)
        }
        val x = lambda.pow(2).subtract(a.affineX).subtract(b.affineX).mod(p)
        val y = lambda.multiply(a.affineX.subtract(x)).subtract(a.affineY).mod(p)
        return ECPoint(x, y)
    }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }

    private fun isOnCurve(x: BigInteger, y: BigInteger): Boolean {
        val c = curve.curve
        val p = (c.field as ECFieldFp).p
        if (x.signum() < 0 || x >= p || y.signum() < 0 || y >= p) return false
        val lhs = y.multiply(y).mod(p)
        val rhs = x.pow(3).add(c.a.multiply(x)).add(c.b).mod(p)
        return lhs == rhs
    }

    private fun fixed32(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32 - raw.size) + raw
        }
    }
}

/** A device's mesh identity: a P-256 key pair. Peer ID = first 8 bytes of SHA-256(public key). */
class MeshIdentity(val privateKey: PrivateKey, val publicKey: ByteArray) {
    val peerId: ByteArray = MeshCrypto.peerId(publicKey)
    val peerIdHex: String = peerId.toHex()

    companion object {
        fun generate(): MeshIdentity = of(MeshCrypto.generateKeyPair())

        fun of(pair: KeyPair): MeshIdentity = MeshIdentity(pair.private, MeshCrypto.encodePublicKey(pair.public))
    }
}

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
