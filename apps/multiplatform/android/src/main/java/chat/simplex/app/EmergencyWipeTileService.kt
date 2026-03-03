package chat.simplex.app

import android.content.Intent
import android.os.Build
import android.service.quicksettings.TileService

class EmergencyWipeTileService : TileService() {

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, EmergencyWipeConfirmActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(android.app.PendingIntent.getActivity(this, 0, intent, android.app.PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
