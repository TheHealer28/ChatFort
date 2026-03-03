package chat.simplex.app.nearby

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Cryptographic utilities for Nearby Chat.
 * - HKDF-SHA256 key derivation from room code
 * - AES-256-GCM encryption/decryption
 * - Room code hashing for BLE advertising
 */
/** Hex-encode a ByteArray */
fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

object NearbyCrypto {

    private const val AES_KEY_SIZE = 32  // 256 bits
    private const val GCM_IV_SIZE = 12   // 96 bits
    private const val GCM_TAG_BITS = 128

    // App-specific salt for HKDF — never changes
    private val HKDF_SALT = "InqalaabNearbyChatV1".toByteArray(Charsets.UTF_8)
    private val HKDF_INFO = "room-encryption-key".toByteArray(Charsets.UTF_8)

    /**
     * Derive an AES-256 key from a room code using HKDF-SHA256.
     * Same code always produces the same key.
     */
    fun deriveKey(roomCode: String): SecretKeySpec {
        val ikm = roomCode.uppercase().toByteArray(Charsets.UTF_8)
        val prk = hkdfExtract(HKDF_SALT, ikm)
        val okm = hkdfExpand(prk, HKDF_INFO, AES_KEY_SIZE)
        return SecretKeySpec(okm, "AES")
    }

    /**
     * Encrypt plaintext with AES-256-GCM.
     * Returns: IV (12 bytes) || ciphertext || GCM tag
     */
    fun encrypt(plaintext: ByteArray, key: SecretKeySpec): ByteArray {
        val iv = ByteArray(GCM_IV_SIZE).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        val ciphertext = cipher.doFinal(plaintext)
        return iv + ciphertext  // IV || ciphertext+tag
    }

    /**
     * Decrypt data produced by [encrypt].
     * Input: IV (12 bytes) || ciphertext || GCM tag
     */
    fun decrypt(data: ByteArray, key: SecretKeySpec): ByteArray {
        require(data.size > GCM_IV_SIZE) { "Data too short to contain IV" }
        val iv = data.copyOfRange(0, GCM_IV_SIZE)
        val ciphertext = data.copyOfRange(GCM_IV_SIZE, data.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    /**
     * SHA-256 hash of room code, truncated to 8 bytes.
     * Used in BLE advertising data to identify rooms without revealing the code.
     */
    fun hashRoomCode(roomCode: String): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(roomCode.uppercase().toByteArray(Charsets.UTF_8))
        return hash.copyOfRange(0, 8)
    }

    // --- HKDF implementation (RFC 5869) ---

    private fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val hashLen = 32  // SHA-256 output
        val n = (length + hashLen - 1) / hashLen
        var t = ByteArray(0)
        val okm = ByteArray(length)
        var offset = 0
        for (i in 1..n) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(byteArrayOf(i.toByte()))
            t = mac.doFinal()
            val copyLen = minOf(hashLen, length - offset)
            System.arraycopy(t, 0, okm, offset, copyLen)
            offset += copyLen
        }
        return okm
    }
}
