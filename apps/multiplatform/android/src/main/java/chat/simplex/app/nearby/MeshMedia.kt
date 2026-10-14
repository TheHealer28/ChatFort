package chat.simplex.app.nearby

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import androidx.core.content.FileProvider
import chat.simplex.common.platform.Log
import chat.simplex.common.platform.TAG
import chat.simplex.mesh.protocol.MediaType
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Photos and voice notes for the crowd mesh (wire v3): small enough to cross several Bluetooth hops.
 * - Photos: re-encoded JPEG (so no EXIF or location), long edge at most 1024, at most 48 KB.
 * - Voice: AAC (HE-AAC, or AAC-LC where unavailable) in .m4a, mono 16 kHz ~16 kbps, at most 30 s.
 */
object MeshMedia {
    class Photo(val data: ByteArray, val width: Int, val height: Int)

    private const val MAX_EDGE = 1024
    const val MAX_VOICE_MS = 30_000

    /** Shrinks the picture at [uri] to fit a mesh photo. Null if it can't be read. Not on the main thread. */
    fun preparePhoto(context: Context, uri: Uri): Photo? = try {
        val source = decode(context, uri) ?: return null
        var edge = minOf(MAX_EDGE, maxOf(source.width, source.height))
        var result: Photo? = null
        while (result == null && edge >= 160) {
            val scale = edge.toFloat() / maxOf(source.width, source.height)
            val w = maxOf(1, (source.width * scale).toInt())
            val h = maxOf(1, (source.height * scale).toInt())
            val scaled = if (w == source.width && h == source.height) source else Bitmap.createScaledBitmap(source, w, h, true)
            for (quality in intArrayOf(70, 55, 42, 30, 20)) {
                val out = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, quality, out)
                if (out.size() <= MediaType.PHOTO.maxBytes) {
                    result = Photo(out.toByteArray(), w, h)
                    break
                }
            }
            if (scaled !== source) scaled.recycle()
            edge = (edge * 0.75f).toInt()
        }
        source.recycle()
        result
    } catch (e: Exception) {
        Log.e(TAG, "mesh photo: ${e.message}")
        null
    }

    private fun decode(context: Context, uri: Uri): Bitmap? =
        if (Build.VERSION.SDK_INT >= 28) {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val size = info.size
                val longest = maxOf(size.width, size.height)
                // Decode near the target size: phone cameras' full resolution would waste memory.
                if (longest > MAX_EDGE * 2) {
                    val f = MAX_EDGE * 2f / longest
                    decoder.setTargetSize(maxOf(1, (size.width * f).toInt()), maxOf(1, (size.height * f).toInt()))
                }
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_EDGE) sample *= 2
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
        }

    /** A file the camera app can write a new photo to (in app-private storage), and its shareable URI. */
    fun cameraTarget(context: Context): Pair<File, Uri> {
        val dir = File(context.filesDir, "mesh_tmp").apply { mkdirs() }
        val file = File(dir, "camera.jpg").apply { delete() }
        return file to FileProvider.getUriForFile(context, "${context.packageName}.provider", file)
    }

    fun decodeForDisplay(data: ByteArray): Bitmap? = try {
        BitmapFactory.decodeByteArray(data, 0, data.size)
    } catch (_: Exception) {
        null
    }

    /** Records one voice note. Call [start], then [stop] (or [cancel]); not reusable. */
    class VoiceRecorder(private val context: Context) {
        private var recorder: MediaRecorder? = null
        private val file = File(File(context.cacheDir, "mesh_tmp").apply { mkdirs() }, "voice.m4a")
        private var startedAt = 0L

        /** False if the microphone can't be used. */
        fun start(): Boolean {
            file.delete()
            for (encoder in intArrayOf(MediaRecorder.AudioEncoder.HE_AAC, MediaRecorder.AudioEncoder.AAC)) {
                val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
                try {
                    r.setAudioSource(MediaRecorder.AudioSource.MIC)
                    r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                    r.setAudioEncoder(encoder)
                    r.setAudioChannels(1)
                    r.setAudioSamplingRate(16_000)
                    r.setAudioEncodingBitRate(16_000)
                    r.setMaxDuration(MAX_VOICE_MS)
                    r.setOutputFile(file.absolutePath)
                    r.prepare()
                    r.start()
                    recorder = r
                    startedAt = SystemClock.elapsedRealtime()
                    return true
                } catch (e: Exception) {
                    Log.w(TAG, "mesh voice: encoder $encoder unavailable: ${e.message}")
                    try { r.release() } catch (_: Exception) { }
                }
            }
            return false
        }

        val elapsedMs: Long get() = if (recorder == null) 0 else SystemClock.elapsedRealtime() - startedAt

        /** The recording and its length, or null if it failed or is too short or too big. */
        fun stop(): Pair<ByteArray, Int>? {
            val r = recorder ?: return null
            recorder = null
            val duration = minOf(MAX_VOICE_MS.toLong(), SystemClock.elapsedRealtime() - startedAt).toInt()
            val ok = try { r.stop(); true } catch (_: Exception) { false }
            try { r.release() } catch (_: Exception) { }
            val data = if (ok && file.exists()) file.readBytes() else null
            file.delete()
            if (data == null || duration < 700 || data.isEmpty() || data.size > MediaType.VOICE.maxBytes) return null
            return data to duration
        }

        fun cancel() {
            val r = recorder ?: return
            recorder = null
            try { r.stop() } catch (_: Exception) { }
            try { r.release() } catch (_: Exception) { }
            file.delete()
        }
    }

    /** Plays one voice note from memory (via a private temp file, deleted when done). */
    class VoicePlayer(private val context: Context) {
        private var player: MediaPlayer? = null
        private var file: File? = null

        fun play(data: ByteArray, onDone: () -> Unit): Boolean {
            stop()
            return try {
                val f = File(File(context.cacheDir, "mesh_tmp").apply { mkdirs() }, "play.m4a").apply { writeBytes(data) }
                file = f
                player = MediaPlayer().apply {
                    setDataSource(f.absolutePath)
                    setOnCompletionListener { stop(); onDone() }
                    prepare()
                    start()
                }
                true
            } catch (e: Exception) {
                Log.e(TAG, "mesh voice playback: ${e.message}")
                stop()
                false
            }
        }

        fun stop() {
            player?.let { try { it.stop() } catch (_: Exception) { }; it.release() }
            player = null
            file?.delete()
            file = null
        }
    }
}
