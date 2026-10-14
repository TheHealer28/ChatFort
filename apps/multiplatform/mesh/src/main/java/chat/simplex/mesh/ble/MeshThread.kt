package chat.simplex.mesh.ble

import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import chat.simplex.mesh.core.MeshScheduler

/** The single thread that owns all mesh and Bluetooth state. */
class MeshThread(name: String = "chatfort-mesh") : MeshScheduler {
    private val thread = HandlerThread(name).apply { start() }
    private val handler = Handler(thread.looper)

    fun post(task: () -> Unit) {
        handler.post { run(task) }
    }

    override fun schedule(delayMs: Long, task: () -> Unit) {
        handler.postDelayed({ run(task) }, delayMs)
    }

    fun isCurrent(): Boolean = Thread.currentThread() == thread

    fun quit() {
        handler.removeCallbacksAndMessages(null)
        thread.quitSafely()
    }

    private fun run(task: () -> Unit) {
        try {
            task()
        } catch (e: Throwable) {
            Log.e("CrowdMesh", "mesh task failed", e)
        }
    }
}
