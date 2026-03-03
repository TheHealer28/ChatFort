package chat.simplex.app

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle
import chat.simplex.common.views.helpers.withLongRunningApi
import chat.simplex.common.views.safetyhub.performEmergencyWipe

class EmergencyWipeConfirmActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        AlertDialog.Builder(this)
            .setTitle("Reset App")
            .setMessage("This will permanently delete all messages, contacts, and files. A new empty profile will be created. This cannot be undone.")
            .setPositiveButton("Reset") { _, _ ->
                performWipe()
            }
            .setNegativeButton("Cancel") { _, _ ->
                finish()
            }
            .setOnCancelListener {
                finish()
            }
            .show()
    }

    private fun performWipe() {
        withLongRunningApi {
            performEmergencyWipe()
        }
        finish()
    }
}
