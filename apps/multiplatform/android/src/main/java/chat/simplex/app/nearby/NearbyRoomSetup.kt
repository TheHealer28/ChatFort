package chat.simplex.app.nearby

import android.Manifest
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import chat.simplex.common.model.ChatModel
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.chatlist.LocalTabBarHeight

/**
 * Room setup screen: Create or Join a nearby chat room.
 * Handles permission requests for Bluetooth and Location.
 */
@Composable
fun NearbyRoomSetup(onRoomReady: () -> Unit, onBack: () -> Unit = {}) {
    val context = LocalContext.current
    val state = NearbyUiState.connectionState.value
    val errorMsg = NearbyUiState.errorMessage.value
    val displayName = ChatModel.currentUser.value?.displayName ?: "User"

    var showJoinInput by remember { mutableStateOf(false) }

    // System back button: go back to join input → main menu → Internet mode
    BackHandler {
        if (showJoinInput) {
            showJoinInput = false
        } else {
            NearbyUiState.reset()
            onBack()
        }
    }
    var joinCode by remember { mutableStateOf("") }
    var roomCode by remember { mutableStateOf<String?>(null) }
    var permissionsGranted by remember { mutableStateOf(false) }

    // Check and request permissions
    val requiredPermissions = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_ADVERTISE)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
    }.toTypedArray()

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        permissionsGranted = results.values.all { it }
    }

    // Check if Bluetooth is enabled (required for BLE discovery)
    val bluetoothManager = context.getSystemService(android.content.Context.BLUETOOTH_SERVICE) as? android.bluetooth.BluetoothManager
    val bluetoothEnabled = bluetoothManager?.adapter?.isEnabled == true

    // Check if Location Services are enabled (required for WiFi Direct)
    val locationManager = context.getSystemService(android.content.Context.LOCATION_SERVICE) as? LocationManager
    val locationEnabled = locationManager?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true
        || locationManager?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true

    LaunchedEffect(Unit) {
        permissionsGranted = requiredPermissions.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
        if (!permissionsGranted) {
            permissionLauncher.launch(requiredPermissions)
        }
    }

    // Transition to chat view when connected
    LaunchedEffect(state) {
        if (state == NearbyConnectionState.CONNECTED) {
            onRoomReady()
        }
    }

    val tabBarHeight = LocalTabBarHeight.current
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(horizontal = DEFAULT_PADDING)
            .padding(top = 8.dp, bottom = tabBarHeight),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Back to Internet mode
        Row(Modifier.fillMaxWidth()) {
            TextButton(onClick = {
                NearbyUiState.reset()
                onBack()
            }) {
                Text("← Back to Chats", color = MaterialTheme.colors.primary)
            }
        }

        Spacer(Modifier.height(8.dp))

        Text(
            "Nearby Chat",
            style = MaterialTheme.typography.h1,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colors.primary
        )

        Spacer(Modifier.height(8.dp))

        Text(
            "Chat with people nearby without internet",
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.secondary,
            textAlign = TextAlign.Center
        )

        Spacer(Modifier.height(8.dp))

        Text(
            "Messages are ephemeral and disappear when you leave.",
            style = MaterialTheme.typography.body2,
            color = MaterialTheme.colors.secondary.copy(alpha = 0.7f),
            textAlign = TextAlign.Center
        )

        Spacer(Modifier.weight(1f))

        if (!permissionsGranted) {
            Text(
                "Nearby Chat needs Bluetooth and Location permissions to find devices nearby.",
                style = MaterialTheme.typography.body1,
                color = MaterialTheme.colors.error,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(16.dp)
            )
            Button(
                onClick = { permissionLauncher.launch(requiredPermissions) },
                colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.primary),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().height(50.dp)
            ) {
                Text("Grant Permissions", color = MaterialTheme.colors.onPrimary)
            }
        } else if (!bluetoothEnabled) {
            Text(
                "Bluetooth must be turned ON to discover nearby devices.",
                style = MaterialTheme.typography.body1,
                color = MaterialTheme.colors.error,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(16.dp)
            )
            Button(
                onClick = {
                    context.startActivity(android.content.Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
                },
                colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.primary),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().height(50.dp)
            ) {
                Text("Open Bluetooth Settings", color = MaterialTheme.colors.onPrimary)
            }
        } else if (!locationEnabled) {
            Text(
                "Location Services must be turned ON for WiFi Direct to discover nearby devices.",
                style = MaterialTheme.typography.body1,
                color = MaterialTheme.colors.error,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(16.dp)
            )
            Button(
                onClick = {
                    context.startActivity(android.content.Intent(android.provider.Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                },
                colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.primary),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().height(50.dp)
            ) {
                Text("Open Location Settings", color = MaterialTheme.colors.onPrimary)
            }
        } else if (state == NearbyConnectionState.CREATING_ROOM || state == NearbyConnectionState.JOINING_ROOM) {
            // Loading state
            CircularProgressIndicator(Modifier.size(48.dp), color = MaterialTheme.colors.primary)
            Spacer(Modifier.height(16.dp))
            Text(
                if (state == NearbyConnectionState.CREATING_ROOM) "Creating room…" else "Joining room…",
                style = MaterialTheme.typography.body1,
                color = MaterialTheme.colors.secondary
            )
            if (roomCode != null) {
                Spacer(Modifier.height(24.dp))
                Text("Room Code", style = MaterialTheme.typography.body2, color = MaterialTheme.colors.secondary)
                Text(
                    roomCode!!,
                    style = MaterialTheme.typography.h1,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 8.sp,
                    color = MaterialTheme.colors.primary
                )
                Text(
                    "Share this code with people nearby",
                    style = MaterialTheme.typography.body2,
                    color = MaterialTheme.colors.secondary
                )
            }
        } else if (showJoinInput) {
            // Join room input
            Text(
                "Enter Room Code",
                style = MaterialTheme.typography.h3,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colors.onBackground
            )

            Spacer(Modifier.height(16.dp))

            OutlinedTextField(
                value = joinCode,
                onValueChange = { if (it.length <= 6) joinCode = it.uppercase() },
                placeholder = { Text("e.g. ABC123") },
                textStyle = MaterialTheme.typography.h2.copy(
                    letterSpacing = 4.sp,
                    textAlign = TextAlign.Center
                ),
                singleLine = true,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.Characters,
                    imeAction = ImeAction.Go
                ),
                keyboardActions = KeyboardActions(
                    onGo = {
                        if (joinCode.length == 6) {
                            NearbyManager.joinRoom(joinCode, displayName) {}
                        }
                    }
                ),
                modifier = Modifier.fillMaxWidth().height(64.dp),
                shape = RoundedCornerShape(12.dp)
            )

            Spacer(Modifier.height(16.dp))

            Button(
                onClick = {
                    NearbyManager.joinRoom(joinCode, displayName) {}
                },
                enabled = joinCode.length == 6,
                colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.primary),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().height(50.dp)
            ) {
                Text("Join", color = MaterialTheme.colors.onPrimary, fontWeight = FontWeight.Bold)
            }

            Spacer(Modifier.height(8.dp))

            TextButton(onClick = { showJoinInput = false }) {
                Text("Back", color = MaterialTheme.colors.primary)
            }
        } else {
            // Main menu: Create or Join
            Button(
                onClick = {
                    NearbyManager.createRoom(displayName) { code ->
                        roomCode = code
                    }
                },
                colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.primary),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().height(56.dp)
            ) {
                Text("Create Room", color = MaterialTheme.colors.onPrimary, fontWeight = FontWeight.Bold, fontSize = 16.sp)
            }

            Spacer(Modifier.height(16.dp))

            OutlinedButton(
                onClick = { showJoinInput = true },
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().height(56.dp)
            ) {
                Text("Join Room", fontWeight = FontWeight.Bold, fontSize = 16.sp)
            }

            Spacer(Modifier.height(24.dp))

            Divider(color = MaterialTheme.colors.secondary.copy(alpha = 0.2f))

            Spacer(Modifier.height(16.dp))

            Text(
                "Looking for someone?",
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(Modifier.height(8.dp))

            OutlinedButton(
                onClick = { NearbyManager.startPeopleDiscovery() },
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().height(56.dp)
            ) {
                Text("Find People Nearby", fontWeight = FontWeight.Bold, fontSize = 16.sp)
            }
        }

        // Error display
        if (errorMsg != null && state == NearbyConnectionState.ERROR) {
            Spacer(Modifier.height(16.dp))
            Text(
                errorMsg,
                color = MaterialTheme.colors.error,
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.body2
            )
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = { NearbyUiState.reset() }) {
                Text("Try Again", color = MaterialTheme.colors.primary)
            }
        }

        Spacer(Modifier.weight(1f))
    }
}
