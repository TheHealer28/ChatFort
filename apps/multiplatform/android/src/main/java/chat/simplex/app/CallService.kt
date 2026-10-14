package chat.simplex.app

import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import chat.simplex.app.model.NtfManager.EndCallAction
import chat.simplex.app.views.call.CallActivity
import chat.simplex.common.model.NotificationPreviewMode
import chat.simplex.common.platform.*
import chat.simplex.common.views.helpers.*
import chat.simplex.res.MR
import kotlinx.datetime.Instant

class CallService: Service() {
  private var wakeLock: PowerManager.WakeLock? = null
  private var notificationManager: NotificationManager? = null
  private var serviceNotification: Notification? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    Log.d(TAG, "onStartCommand startId: $startId")
    if (intent != null) {
      val action = intent.action
      Log.d(TAG, "intent action $action")
      when (action) {
        Action.START.name -> startService()
        else -> Log.e(TAG, "No action in the intent")
      }
    } else {
      Log.d(TAG, "null intent. Probably restarted by the system.")
    }
    ServiceCompat.startForeground(this, CALL_SERVICE_ID, createNotificationIfNeeded(), foregroundServiceType())
    return START_STICKY
  }

  override fun onCreate() {
    super.onCreate()
    Log.d(TAG, "Call service created")
    notificationManager = createNotificationChannel()
    ServiceCompat.startForeground(this, CALL_SERVICE_ID, updateNotification(), foregroundServiceType())
  }

  override fun onDestroy() {
    Log.d(TAG, "Call service destroyed")
    try {
      wakeLock?.let {
        while (it.isHeld) it.release() // release all, in case acquired more than once
      }
      wakeLock = null
    } catch (e: Exception) {
      Log.d(TAG, "Exception while releasing wakelock: ${e.message}")
    }
    super.onDestroy()
  }

  private fun startService() {
    Log.d(TAG, "CallService startService")
    if (wakeLock != null) return
    wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager).run {
      newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
        acquire()
      }
    }
  }

  private fun createNotificationIfNeeded(): Notification {
    val ntf = serviceNotification
    if (ntf != null) return ntf

    return updateNotification()
  }

  fun updateNotification(): Notification {
    val call = chatModel.activeCall.value
    val previewMode = appPreferences.notificationPreviewMode.get()
    val title = if (previewMode == NotificationPreviewMode.HIDDEN.name)
      generalGetString(MR.strings.notification_preview_somebody)
    else
      call?.contact?.profile?.displayName ?: ""
    val text = generalGetString(if (call?.hasVideo == true) MR.strings.call_service_notification_video_call else MR.strings.call_service_notification_audio_call)
    val image = call?.contact?.image
    val largeIcon = if (image == null || previewMode == NotificationPreviewMode.HIDDEN.name)
      BitmapFactory.decodeResource(resources, R.drawable.icon)
    else
      base64ToBitmap(image).asAndroidBitmap()

    val ntf = createNotification(title, text, largeIcon, call?.connectedAt)
    serviceNotification = ntf
    ServiceCompat.startForeground(this, CALL_SERVICE_ID, ntf, foregroundServiceType())
    return ntf
  }

  private fun foregroundServiceType(): Int {
    val call = chatModel.activeCall.value
    return if (call == null) {
      if (Build.VERSION.SDK_INT >= 34) {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
      } else {
        0
      }
    } else if (Build.VERSION.SDK_INT >= 30) {
      if (call.hasVideo && ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
      } else {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
      }
    } else if (Build.VERSION.SDK_INT >= 29) {
      ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
    } else {
      0
    }
  }

  private fun createNotificationChannel(): NotificationManager? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      val channel = NotificationChannel(CALL_NOTIFICATION_CHANNEL_ID, CALL_NOTIFICATION_CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH)
      channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
      notificationManager.createNotificationChannel(channel)
      return notificationManager
    }
    return null
  }

  private fun createNotification(title: String, text: String, icon: Bitmap, connectedAt: Instant? = null): Notification {
    val call = chatModel.activeCall.value
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && call != null) {
      createOngoingCallStyleNotification(call, title, text, icon, connectedAt)
    } else {
      createLegacyOngoingCallNotification(title, text, icon, connectedAt)
    }
  }

  private fun createLegacyOngoingCallNotification(title: String, text: String, icon: Bitmap, connectedAt: Instant? = null): Notification {
    val pendingIntent = buildCallContentIntent()
    val endCallPendingIntent = buildEndCallPendingIntent()

    val builder = NotificationCompat.Builder(this, CALL_NOTIFICATION_CHANNEL_ID)
      .setSmallIcon(R.drawable.ntf_icon)
      .setColor(0xFF1B1B1B.toInt()) // ChatFort: logo background, not the One UI default teal
      .setLargeIcon(icon.clipToCircle())
      .setColor(0x88FFFF)
      .setContentTitle(title)
      .setContentText(text)
      .setContentIntent(pendingIntent)
      .setSilent(true)
      .setOngoing(true)
      .setCategory(NotificationCompat.CATEGORY_CALL)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
      .addAction(R.drawable.ntf_icon, generalGetString(MR.strings.call_service_notification_end_call), endCallPendingIntent)
    if (connectedAt != null) {
      builder.setUsesChronometer(true)
      builder.setWhen(connectedAt.epochSeconds * 1000)
    }

    return builder.build()
  }

  @androidx.annotation.RequiresApi(Build.VERSION_CODES.S)
  private fun createOngoingCallStyleNotification(call: chat.simplex.common.views.call.Call, title: String, text: String, icon: Bitmap, connectedAt: Instant? = null): Notification {
    val pendingIntent = buildCallContentIntent()
    val endCallPendingIntent = buildEndCallPendingIntent()
    val style = NotificationCompat.CallStyle
      .forOngoingCall(buildCallPerson(title), endCallPendingIntent)
      .setIsVideo(call.hasVideo)

    val builder = NotificationCompat.Builder(this, CALL_NOTIFICATION_CHANNEL_ID)
      .setSmallIcon(R.drawable.ntf_icon)
      .setColor(0xFF1B1B1B.toInt()) // ChatFort: logo background, not the One UI default teal
      .setLargeIcon(icon.clipToCircle())
      .setColor(0x88FFFF)
      .setContentTitle(title)
      .setContentText(text)
      .setContentIntent(pendingIntent)
      .setSilent(true)
      .setOngoing(true)
      .setCategory(NotificationCompat.CATEGORY_CALL)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
      .setStyle(style)
    if (connectedAt != null) {
      builder.setUsesChronometer(true)
      builder.setWhen(connectedAt.epochSeconds * 1000)
      builder.setShowWhen(true)
    }

    return builder.build()
  }

  private fun buildCallContentIntent(): PendingIntent =
    Intent(this, CallActivity::class.java).let { notificationIntent ->
      PendingIntent.getActivity(this, 0, notificationIntent, PendingIntent.FLAG_IMMUTABLE)
    }

  private fun buildEndCallPendingIntent(): PendingIntent =
    Intent(this, CallActionReceiver::class.java).let { notificationIntent ->
      notificationIntent.setAction(EndCallAction)
      PendingIntent.getBroadcast(this, 1, notificationIntent, PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

  private fun buildCallPerson(title: String): Person =
    Person.Builder()
      .setName(title.ifBlank { generalGetString(MR.strings.notification_preview_somebody) })
      .setImportant(true)
      .build()

  override fun onBind(intent: Intent): IBinder {
    return CallServiceBinder()
  }

  inner class CallServiceBinder : Binder() {
    fun getService() = this@CallService
  }

  enum class Action {
    START,
  }

  class CallActionReceiver: BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      when (intent?.action) {
        EndCallAction -> {
          val call = chatModel.activeCall.value
          if (call != null) {
            withBGApi {
              chatModel.callManager.endCall(call)
            }
          }
        }
        else -> {
          Log.e(TAG, "Unknown action. Make sure you provided an action")
        }
      }
    }
  }

companion object {
    const val TAG = "CALL_SERVICE"
    const val CALL_NOTIFICATION_CHANNEL_ID = "chat.simplex.app.CALL_SERVICE_NOTIFICATION"
    const val CALL_NOTIFICATION_CHANNEL_NAME = "ChatFort call service"
    const val CALL_SERVICE_ID = 6788
    const val WAKE_LOCK_TAG = "CallService::lock"

    fun startService(): Intent {
      Log.d(TAG, "CallService start")
      return Intent(androidAppContext, CallService::class.java).also {
        it.action = Action.START.name
        ContextCompat.startForegroundService(androidAppContext, it)
      }
    }

    fun stopService() {
      androidAppContext.stopService(Intent(androidAppContext, CallService::class.java))
    }
  }
}
