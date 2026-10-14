package chat.simplex.mesh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import chat.simplex.mesh.core.ContactChannel
import chat.simplex.mesh.core.TeamChannel
import chat.simplex.mesh.protocol.MeshCrypto
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Persists a nickname the user chose, the team channel keys and (wire v3) linked contacts: their pair
 * keys, link state and chats. Everything secret is encrypted with an AES key held in the Android
 * Keystore; only each team's and pair's current day key is stored (see [TeamChannel], [ContactChannel]).
 * Public and team messages, the mesh identity and random session nicknames are never stored.
 */
internal class MeshStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val dir = File(context.filesDir, DIR)

    /** Null until the user picks a nickname: then each session gets a new random one. */
    var nickname: String?
        get() = prefs.getString(KEY_NICKNAME, null)
        set(value) { prefs.edit().putString(KEY_NICKNAME, value).apply() }

    fun loadChannels(): List<TeamChannel> {
        val saved = prefs.getString(KEY_CHANNELS, null) ?: return emptyList()
        return try {
            val json = JSONArray(String(unwrap(Base64.decode(saved, Base64.NO_WRAP)), Charsets.UTF_8))
            List(json.length()) { i ->
                val o = json.getJSONObject(i)
                TeamChannel.restore(
                    TeamChannel.Persisted(
                        localId = o.getString("id"),
                        name = o.getString("name"),
                        day = o.getLong("day"),
                        key = Base64.decode(o.getString("key"), Base64.NO_WRAP),
                        previousKey = o.optString("prev", "").takeIf { it.isNotEmpty() }?.let { Base64.decode(it, Base64.NO_WRAP) }
                    )
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun saveChannels(channels: List<TeamChannel>) {
        val json = JSONArray()
        channels.forEach { c ->
            val p = c.persisted()
            val o = JSONObject()
                .put("id", p.localId)
                .put("name", p.name)
                .put("day", p.day)
                .put("key", Base64.encodeToString(p.key, Base64.NO_WRAP))
            p.previousKey?.let { o.put("prev", Base64.encodeToString(it, Base64.NO_WRAP)) }
            json.put(o)
        }
        val sealed = wrap(json.toString().toByteArray(Charsets.UTF_8))
        prefs.edit().putString(KEY_CHANNELS, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    /** Link state and pair keys of linked contacts, as JSON (see CrowdMesh). */
    fun loadLinks(): JSONObject = loadJson(LINKS_FILE)

    fun saveLinks(json: JSONObject) = saveBlob(LINKS_FILE, json.toString().toByteArray(Charsets.UTF_8))

    /** Chats with linked contacts, as JSON (see CrowdMesh). */
    fun loadContactChats(): JSONObject = loadJson(CHATS_FILE)

    fun saveContactChats(json: JSONObject) = saveBlob(CHATS_FILE, json.toString().toByteArray(Charsets.UTF_8))

    /** A received or sent photo / voice note of a contact chat. */
    fun saveMedia(uidHex: String, data: ByteArray) = saveBlob("$MEDIA_PREFIX$uidHex", data)

    fun loadMedia(uidHex: String): ByteArray? = loadBlob("$MEDIA_PREFIX$uidHex")

    fun deleteMedia(uidHex: String) {
        File(dir, "$MEDIA_PREFIX$uidHex").delete()
    }

    /** Deleted database: every contact's link state, chat and media (teams and nickname stay). */
    fun deleteContacts() {
        dir.listFiles()?.forEach { f ->
            if (f.name.startsWith(LINKS_FILE) || f.name.startsWith(CHATS_FILE) || f.name.startsWith(MEDIA_PREFIX)) f.delete()
        }
    }

    fun mediaFiles(): List<String> = dir.list()?.filter { it.startsWith(MEDIA_PREFIX) }?.map { it.removePrefix(MEDIA_PREFIX) }.orEmpty()

    private fun loadJson(name: String): JSONObject =
        loadBlob(name)?.let { try { JSONObject(String(it, Charsets.UTF_8)) } catch (_: Exception) { null } } ?: JSONObject()

    private fun saveBlob(name: String, plain: ByteArray) {
        dir.mkdirs()
        val tmp = File(dir, "$name.tmp")
        tmp.writeBytes(wrap(plain))
        if (!tmp.renameTo(File(dir, name))) {
            File(dir, name).delete()
            tmp.renameTo(File(dir, name))
        }
    }

    private fun loadBlob(name: String): ByteArray? {
        val f = File(dir, name)
        if (!f.exists()) return null
        return try { unwrap(f.readBytes()) } catch (_: Exception) { null }
    }

    /** Emergency wipe: nickname, team keys, linked contacts and their chats, and the Keystore key. */
    fun wipe() {
        prefs.edit().clear().commit()
        dir.listFiles()?.forEach { it.delete() }
        dir.delete()
        try {
            KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(WRAP_ALIAS)
        } catch (_: Exception) {
        }
    }

    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (ks.getKey(WRAP_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(WRAP_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private fun wrap(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        return cipher.iv + cipher.doFinal(plain)
    }

    private fun unwrap(sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, sealed, 0, 12))
        return cipher.doFinal(sealed, 12, sealed.size - 12)
    }

    companion object {
        private const val PREFS = "chatfort_crowd_mesh"
        // v2 keys: team data saved by test builds of wire version 1 is not read (its format differs).
        private const val KEY_NICKNAME = "nickname_v2"
        private const val KEY_CHANNELS = "channels_v2"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val WRAP_ALIAS = "chatfort_crowd_mesh_wrap"
        private const val DIR = "crowd_mesh"
        private const val LINKS_FILE = "links_v3"
        private const val CHATS_FILE = "contact_chats_v3"
        private const val MEDIA_PREFIX = "media_"

        fun randomNickname() = "anon${1000 + Math.floorMod(MeshCrypto.randomInt(), 9000)}"
    }
}
