package chat.simplex.mesh

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/** Keeps the crowd mesh relaying while the screen is off, with an ongoing notification and a Stop action. */
class CrowdMeshService : Service() {

    companion object {
        private const val CHANNEL_ID = "chatfort_crowd_mesh_service"
        private const val NOTIFICATION_ID = 10_301
        private const val ACTION_STOP = "chat.simplex.mesh.STOP"
        private const val UPDATE_MS = 10_000L

        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, CrowdMeshService::class.java))
            } catch (e: Exception) {
                // e.g. started from the background on Android 12+: the mesh still runs while the app is open.
                Log.w("CrowdMesh", "foreground service not started: ${e.message}")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CrowdMeshService::class.java))
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var lastCount = -1

    private val updater = object : Runnable {
        override fun run() {
            val count = CrowdMesh.status.value.linkedPhones
            if (count != lastCount) {
                lastCount = count
                getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification(count))
            }
            handler.postDelayed(this, UPDATE_MS)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            CrowdMesh.stop()
            stopSelf()
            return START_NOT_STICKY
        }
        createChannel()
        if (!startInForeground(notification(CrowdMesh.status.value.linkedPhones))) {
            stopSelf()
            return START_NOT_STICKY
        }
        // Restarted by Android after the process was killed: bring the mesh back.
        if (intent == null) CrowdMesh.startEngine()
        handler.removeCallbacks(updater)
        handler.post(updater)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(updater)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notification(linkedPhones: Int): Notification {
        val stop = PendingIntent.getService(
            this, 0, Intent(this, CrowdMeshService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val open = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(CrowdMesh.EXTRA_OPEN_CROWD_MESH, true)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_crowd_mesh)
            .setColor(0xFF1B1B1B.toInt()) // ChatFort: logo background, not the One UI default teal
            .setContentTitle(getString(R.string.crowd_mesh_title))
            .setContentText(resources.getQuantityString(R.plurals.crowd_mesh_service_text, linkedPhones, linkedPhones))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            // Nothing on the lock screen: a locked phone shouldn't show that it runs the mesh.
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .addAction(0, getString(R.string.crowd_mesh_stop), stop)
            .apply {
                if (open != null) setContentIntent(PendingIntent.getActivity(this@CrowdMeshService, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            }
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.crowd_mesh_service_channel), NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
            }
        )
    }

    /**
     * connectedDevice covers the Bluetooth links. On Android 10-11 only, where a BLE scan is a location
     * scan, the location type (with the location permission) keeps scanning with the screen off.
     * From Android 12 the scan permission is "never for location", so location is never used; the
     * app doesn't declare FOREGROUND_SERVICE_LOCATION (Android 14+) at all.
     */
    private fun startInForeground(notification: Notification): Boolean {
        if (Build.VERSION.SDK_INT < 29) {
            startForeground(NOTIFICATION_ID, notification)
            return true
        }
        val needsLocationType = Build.VERSION.SDK_INT < Build.VERSION_CODES.S && (
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
            )
        val base = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        val types = if (needsLocationType) base or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else base
        return try {
            startForeground(NOTIFICATION_ID, notification, types)
            true
        } catch (e: Exception) {
            try {
                startForeground(NOTIFICATION_ID, notification, base)
                true
            } catch (e2: Exception) {
                Log.w("CrowdMesh", "could not run in the foreground: ${e2.message}")
                false
            }
        }
    }
}
