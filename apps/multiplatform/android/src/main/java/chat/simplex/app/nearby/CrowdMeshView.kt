package chat.simplex.app.nearby

import android.Manifest
import android.annotation.SuppressLint
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.bluetooth.BluetoothManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.PersistableBundle
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import boofcv.alg.fiducial.qrcode.QrCode
import chat.simplex.common.ui.theme.DEFAULT_PADDING
import chat.simplex.common.views.chatlist.LocalTabBarHeight
import chat.simplex.common.views.newchat.QRCodeScanner
import chat.simplex.common.views.newchat.qrCodeBitmap
import chat.simplex.mesh.CrowdMesh
import chat.simplex.mesh.protocol.MediaType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import chat.simplex.res.MR
import chat.simplex.common.views.helpers.generalGetString
import dev.icerock.moko.resources.StringResource
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import java.text.SimpleDateFormat
import java.util.*

private enum class MeshSection(val label: StringResource) {
    EVERYONE(MR.strings.mesh_tab_everyone), TEAMS(MR.strings.mesh_tab_teams), PEOPLE(MR.strings.mesh_tab_people)
}

/**
 * ChatFort Crowd mesh: multi-hop Bluetooth chat with no internet or mobile network. Messages hop
 * from phone to phone, up to 7 hops. Public crowd chat, encrypted team channels joined by code,
 * and encrypted private messages.
 */
@Composable
fun CrowdMeshView(onBack: () -> Unit) {
    val status by CrowdMesh.status.collectAsState()
    val peers by CrowdMesh.peers.collectAsState()
    val publicMessages by CrowdMesh.publicMessages.collectAsState()
    val teams by CrowdMesh.teams.collectAsState()
    val teamMessages by CrowdMesh.teamMessages.collectAsState()
    val directMessages by CrowdMesh.directMessages.collectAsState()
    val contacts by CrowdMesh.contacts.collectAsState()
    val contactMessages by CrowdMesh.contactMessages.collectAsState()
    val unread by CrowdMesh.unread.collectAsState()

    val context = LocalContext.current
    var section by rememberSaveable { mutableStateOf(MeshSection.EVERYONE) }
    var openTeam by rememberSaveable { mutableStateOf<String?>(null) }
    var openPeer by rememberSaveable { mutableStateOf<String?>(null) }
    var openContact by rememberSaveable { mutableStateOf<String?>(null) }
    var joining by rememberSaveable { mutableStateOf(false) }
    var creatingTeam by remember { mutableStateOf(false) }
    var codeForTeam by remember { mutableStateOf<String?>(null) }
    var confirmLeave by remember { mutableStateOf(false) }
    var confirmStop by remember { mutableStateOf(false) }

    // A team that was left (or wiped) closes.
    LaunchedEffect(teams) {
        if (openTeam != null && teams.none { it.id == openTeam }) openTeam = null
    }

    // The conversation on screen gets no notifications or unread badge, but only while the app is in front.
    val resumed = rememberResumed()
    val peerId = openPeer
    val teamId = openTeam
    val contactId = openContact
    val conversation = when {
        !status.running || !resumed -> null
        contactId != null -> CrowdMesh.contactConversation(contactId)
        peerId != null -> CrowdMesh.directConversation(peerId)
        teamId != null -> CrowdMesh.teamConversation(teamId)
        joining -> null
        section == MeshSection.EVERYONE -> CrowdMesh.PUBLIC_CONVERSATION
        else -> null
    }
    DisposableEffect(conversation) {
        CrowdMesh.visibleConversation = conversation
        if (conversation != null) CrowdMesh.markRead(conversation)
        onDispose { if (CrowdMesh.visibleConversation == conversation) CrowdMesh.visibleConversation = null }
    }

    fun back() {
        when {
            openContact != null -> openContact = null
            openPeer != null -> openPeer = null
            openTeam != null -> openTeam = null
            joining -> joining = false
            else -> onBack()
        }
    }
    BackHandler { back() }

    val team = teams.firstOrNull { it.id == teamId }
    val contact = contacts.firstOrNull { it.id == contactId }
    val title = when {
        contactId != null -> CrowdMesh.contactName(contactId)
        peerId != null -> CrowdMesh.peerNickname(peerId)
        team != null -> team.name
        joining -> stringResource(MR.strings.mesh_join_team_title)
        else -> stringResource(MR.strings.mesh_title)
    }
    val subtitle = when {
        !status.running -> stringResource(MR.strings.mesh_off)
        contactId != null -> contact?.nearbyHops?.let { stringResource(MR.strings.mesh_contact_subtitle).format(distance(it).lowercase()) }
            ?: stringResource(MR.strings.mesh_contact_subtitle_away)
        peerId != null -> peers.firstOrNull { it.peerId == peerId }?.let { stringResource(MR.strings.mesh_private_subtitle).format(distance(it.hops).lowercase()) }
            ?: stringResource(MR.strings.mesh_private_not_in_reach)
        team != null -> stringResource(MR.strings.mesh_team_subtitle)
        else -> stringResource(MR.strings.mesh_status_subtitle).format(phones(status.linkedPhones), people(peers.size))
    }

    Column(Modifier.fillMaxSize().padding(bottom = LocalTabBarHeight.current).imePadding()) {
        CrowdTopBar(title, subtitle, onBack = ::back) {
            when {
                !status.running -> {}
                team != null -> {
                    IconButton(onClick = { codeForTeam = team.id }) {
                        Icon(painterResource(MR.images.ic_qr_code), contentDescription = stringResource(MR.strings.mesh_team_code), tint = MaterialTheme.colors.primary)
                    }
                    IconButton(onClick = { confirmLeave = true }) {
                        Icon(painterResource(MR.images.ic_logout), contentDescription = stringResource(MR.strings.mesh_leave_team), tint = MaterialTheme.colors.error)
                    }
                }
                peerId == null && contactId == null && !joining -> TextButton(onClick = { confirmStop = true }) {
                    Text(stringResource(MR.strings.mesh_stop), color = MaterialTheme.colors.error, fontWeight = FontWeight.Bold)
                }
            }
        }

        if (!status.running) {
            CrowdMeshIntro()
        } else {
            if (status.bluetoothOff) BluetoothOffBanner()
            val backgroundAllowed = remember(resumed) { isBackgroundAllowed(context) }
            if (!backgroundAllowed) BackgroundBanner()
            when {
                contactId != null -> {
                    val name = CrowdMesh.contactName(contactId)
                    // "Are you there?": the answer shows it in reach and sends anything waiting for it.
                    LaunchedEffect(contactId) { CrowdMesh.pingContact(contactId) }
                    Banner(stringResource(MR.strings.mesh_banner_contact).format(name))
                    MessageThread(
                        messages = contactMessages[contactId].orEmpty(),
                        placeholder = stringResource(MR.strings.mesh_placeholder_contact).format(name),
                        showDelivery = true,
                        onSend = { CrowdMesh.sendContactText(contactId, it) },
                        onSendMedia = { type, data, duration, w, h -> CrowdMesh.sendContactMedia(contactId, type, data, duration, w, h, "") }
                    )
                }
                peerId != null -> {
                    Banner(stringResource(MR.strings.mesh_banner_private))
                    val canSend = CrowdMesh.canMessage(peerId)
                    MessageThread(
                        messages = directMessages[peerId].orEmpty(),
                        placeholder = if (canSend) stringResource(MR.strings.mesh_placeholder_private) else stringResource(MR.strings.mesh_placeholder_unreachable),
                        enabled = canSend,
                        showDelivery = true,
                        onSend = { CrowdMesh.sendDirect(peerId, it) }
                    )
                }
                team != null -> {
                    Banner(stringResource(MR.strings.mesh_banner_team))
                    MessageThread(
                        messages = teamMessages[team.id].orEmpty(),
                        placeholder = stringResource(MR.strings.mesh_placeholder_team).format(team.name),
                        onSend = { CrowdMesh.sendTeam(team.id, it) },
                        onSendMedia = { type, data, duration, w, h -> CrowdMesh.sendTeamMedia(team.id, type, data, duration, w, h, "") },
                        mediaNote = stringResource(MR.strings.mesh_team_media_note)
                    )
                }
                joining -> JoinTeam(onJoined = { joined ->
                    joining = false
                    section = MeshSection.TEAMS
                    openTeam = joined.id
                })
                else -> {
                    SectionTabs(section, unread) { section = it }
                    when (section) {
                        MeshSection.EVERYONE -> {
                            Banner(stringResource(MR.strings.mesh_banner_public), warning = true)
                            MessageThread(
                                messages = publicMessages,
                                placeholder = stringResource(MR.strings.mesh_placeholder_public),
                                onSend = { CrowdMesh.sendPublic(it) }
                            )
                        }
                        MeshSection.TEAMS -> TeamList(
                            teams = teams,
                            unread = unread,
                            onOpen = { openTeam = it },
                            onCreate = { creatingTeam = true },
                            onJoin = { joining = true }
                        )
                        MeshSection.PEOPLE -> PeopleList(
                            contacts = contacts,
                            peers = peers,
                            conversations = directMessages.keys,
                            unread = unread,
                            onOpenContact = { openContact = it },
                            onOpen = { openPeer = it }
                        )
                    }
                }
            }
        }
    }

    if (creatingTeam) {
        CreateTeamDialog(
            onDismiss = { creatingTeam = false },
            onCreate = { name ->
                creatingTeam = false
                val created = CrowdMesh.createTeam(name)
                section = MeshSection.TEAMS
                openTeam = created.id
                codeForTeam = created.id
            }
        )
    }
    val codeTeam = teams.firstOrNull { it.id == codeForTeam }
    val code = codeTeam?.let { CrowdMesh.teamCode(it.id) }
    if (codeTeam != null && code != null) TeamCodeDialog(codeTeam.name, code) { codeForTeam = null }
    if (confirmLeave && team != null) {
        AlertDialog(
            onDismissRequest = { confirmLeave = false },
            title = { Text(stringResource(MR.strings.mesh_leave_team_title).format(team.name)) },
            text = { Text(stringResource(MR.strings.mesh_leave_team_text)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmLeave = false
                    openTeam = null
                    CrowdMesh.leaveTeam(team.id)
                }) { Text(stringResource(MR.strings.mesh_leave), color = MaterialTheme.colors.error) }
            },
            dismissButton = { TextButton(onClick = { confirmLeave = false }) { Text(stringResource(MR.strings.mesh_cancel)) } }
        )
    }
    if (confirmStop) {
        AlertDialog(
            onDismissRequest = { confirmStop = false },
            title = { Text(stringResource(MR.strings.mesh_stop_title)) },
            text = { Text(stringResource(MR.strings.mesh_stop_text)) },
            confirmButton = {
                TextButton(onClick = {
                    confirmStop = false
                    CrowdMesh.stop()
                }) { Text(stringResource(MR.strings.mesh_stop), color = MaterialTheme.colors.error) }
            },
            dismissButton = { TextButton(onClick = { confirmStop = false }) { Text(stringResource(MR.strings.mesh_keep_running)) } }
        )
    }
}

@Composable
private fun rememberResumed(): Boolean {
    val owner = LocalLifecycleOwner.current
    var resumed by remember { mutableStateOf(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> resumed = true
                Lifecycle.Event.ON_PAUSE -> resumed = false
                else -> {}
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    return resumed
}

@Composable
private fun CrowdTopBar(title: String, subtitle: String, onBack: () -> Unit, actions: @Composable RowScope.() -> Unit) {
    Surface(Modifier.fillMaxWidth().statusBarsPadding(), elevation = 4.dp, color = MaterialTheme.colors.background) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(painterResource(MR.images.ic_arrow_back_ios_new), contentDescription = stringResource(MR.strings.mesh_back), tint = MaterialTheme.colors.primary)
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.h3, fontWeight = FontWeight.Bold, maxLines = 1)
                Text(subtitle, style = MaterialTheme.typography.body2, color = MaterialTheme.colors.secondary, maxLines = 1)
            }
            actions()
        }
    }
}

@Composable
private fun SectionTabs(selected: MeshSection, unread: Map<String, Int>, onSelect: (MeshSection) -> Unit) {
    Row(Modifier.fillMaxWidth()) {
        MeshSection.entries.forEach { s ->
            val count = when (s) {
                MeshSection.EVERYONE -> unread[CrowdMesh.PUBLIC_CONVERSATION] ?: 0
                MeshSection.TEAMS -> unread.filterKeys { it.startsWith("team:") }.values.sum()
                MeshSection.PEOPLE -> unread.filterKeys { it.startsWith("dm:") }.values.sum()
            }
            val isSelected = s == selected
            Column(
                Modifier.weight(1f).clickable { onSelect(s) }.heightIn(min = 48.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 10.dp)) {
                    Text(
                        stringResource(s.label),
                        fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                        color = if (isSelected) MaterialTheme.colors.primary else MaterialTheme.colors.secondary
                    )
                    if (count > 0) {
                        Spacer(Modifier.width(6.dp))
                        UnreadBadge(count)
                    }
                }
                Box(
                    Modifier.fillMaxWidth().height(3.dp)
                        .background(if (isSelected) MaterialTheme.colors.primary else Color.Transparent)
                )
            }
        }
    }
}

@Composable
private fun UnreadBadge(count: Int) {
    Box(
        Modifier.clip(CircleShape).background(MaterialTheme.colors.primary).padding(horizontal = 6.dp, vertical = 1.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(if (count > 99) "99+" else "$count", color = MaterialTheme.colors.onPrimary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun Banner(text: String, warning: Boolean = false) {
    val color = if (warning) MaterialTheme.colors.error else MaterialTheme.colors.secondary
    Text(
        text,
        style = MaterialTheme.typography.caption,
        color = color,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().background(color.copy(alpha = 0.08f)).padding(vertical = 4.dp, horizontal = 8.dp)
    )
}

@Composable
private fun BluetoothOffBanner() {
    val context = LocalContext.current
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colors.error.copy(alpha = 0.12f)).padding(horizontal = DEFAULT_PADDING, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(stringResource(MR.strings.mesh_bt_off_banner), color = MaterialTheme.colors.error, style = MaterialTheme.typography.body2, modifier = Modifier.weight(1f))
        TextButton(onClick = { context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) }) { Text(stringResource(MR.strings.mesh_turn_on)) }
    }
}

// ---- Running in the background ----

/**
 * True if Android won't pause ChatFort for battery saving: exempt from battery optimisation, and not
 * "restricted" in the app's battery settings. (Uses the app's existing REQUEST_IGNORE_BATTERY_OPTIMIZATIONS.)
 */
private fun isBackgroundAllowed(context: Context): Boolean {
    val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
    val ignoring = pm.isIgnoringBatteryOptimizations(context.packageName)
    val restricted = Build.VERSION.SDK_INT >= 28 &&
        (context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)?.isBackgroundRestricted == true
    return ignoring && !restricted
}

/** Asks for the battery-optimisation exemption, or opens the app's settings if the app is restricted there. */
@SuppressLint("BatteryLife")
private fun requestBackgroundRunning(context: Context) {
    val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    val appSettings = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
    val intent = if (pm != null && !pm.isIgnoringBatteryOptimizations(context.packageName)) {
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
    } else {
        appSettings
    }
    try {
        context.startActivity(intent)
    } catch (_: ActivityNotFoundException) {
        try { context.startActivity(appSettings) } catch (_: ActivityNotFoundException) { }
    }
}

@Composable
private fun BackgroundCard(allowed: Boolean) {
    val context = LocalContext.current
    // Most users already allowed this during onboarding (notification setup): then nothing is shown.
    // It matters when they didn't: notifications off, Android 8-11 with the background service,
    // a declined prompt, or a phone that later put ChatFort to sleep.
    if (allowed) return
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colors.error.copy(alpha = 0.08f)).padding(12.dp)
    ) {
        Text(stringResource(MR.strings.mesh_background_title), style = MaterialTheme.typography.body2, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(4.dp))
        Text(stringResource(MR.strings.mesh_background_text), style = MaterialTheme.typography.body2)
        Spacer(Modifier.height(8.dp))
        OutlinedButton(
            onClick = { requestBackgroundRunning(context) },
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            shape = RoundedCornerShape(16.dp)
        ) { Text(stringResource(MR.strings.mesh_background_button)) }
    }
}

@Composable
private fun BackgroundBanner() {
    val context = LocalContext.current
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colors.error.copy(alpha = 0.12f)).padding(horizontal = DEFAULT_PADDING, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(stringResource(MR.strings.mesh_background_banner), color = MaterialTheme.colors.error, style = MaterialTheme.typography.body2, modifier = Modifier.weight(1f))
        TextButton(onClick = { requestBackgroundRunning(context) }) { Text(stringResource(MR.strings.mesh_background_allow)) }
    }
}

// ---- Start screen ----

private fun meshPermissions(): Array<String> = buildList {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        // Declared "never for location", so Android 12+ needs no location permission at all.
        add(Manifest.permission.BLUETOOTH_SCAN)
        add(Manifest.permission.BLUETOOTH_ADVERTISE)
        add(Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        // Android 11 and older only allow Bluetooth scanning with location permission.
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        add(Manifest.permission.POST_NOTIFICATIONS)
    }
}.toTypedArray()

private fun hasRequiredPermissions(context: Context): Boolean {
    val required = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        listOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }
    return required.all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
}

@Composable
private fun CrowdMeshIntro() {
    val context = LocalContext.current
    var nickname by remember { mutableStateOf(CrowdMesh.nickname()) }
    var permissionsDenied by remember { mutableStateOf(false) }
    var refresh by remember { mutableStateOf(0) }

    // Re-check Bluetooth and Location when coming back from Settings.
    val resumed = rememberResumed()
    LaunchedEffect(resumed) { if (resumed) refresh++ }
    val bluetoothOn = remember(refresh) {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter?.isEnabled == true
    }
    val locationOn = remember(refresh) {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        lm?.isProviderEnabled(LocationManager.GPS_PROVIDER) == true || lm?.isProviderEnabled(LocationManager.NETWORK_PROVIDER) == true
    }
    val needsLocationOn = Build.VERSION.SDK_INT < Build.VERSION_CODES.S

    fun start() {
        CrowdMesh.setNickname(nickname)
        CrowdMesh.start()
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        refresh++
        if (hasRequiredPermissions(context)) {
            permissionsDenied = false
            start()
        } else {
            permissionsDenied = true
        }
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = DEFAULT_PADDING, vertical = 16.dp)
    ) {
        Text(
            stringResource(MR.strings.mesh_intro_title),
            style = MaterialTheme.typography.h4,
            fontWeight = FontWeight.Bold
        )
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(MR.strings.mesh_intro_text),
            style = MaterialTheme.typography.body1,
            color = MaterialTheme.colors.secondary
        )

        Spacer(Modifier.height(20.dp))
        Text(stringResource(MR.strings.mesh_your_nickname), style = MaterialTheme.typography.body2, fontWeight = FontWeight.Bold)
        OutlinedTextField(
            value = nickname,
            onValueChange = { if (it.length <= 24) nickname = it },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )
        Text(
            stringResource(MR.strings.mesh_nickname_warning_intro),
            style = MaterialTheme.typography.caption,
            color = MaterialTheme.colors.error
        )

        Spacer(Modifier.height(20.dp))
        SafetyLine(stringResource(MR.strings.mesh_safety_everyone))
        SafetyLine(stringResource(MR.strings.mesh_safety_teams))
        SafetyLine(stringResource(MR.strings.mesh_safety_people))
        SafetyLine(stringResource(MR.strings.mesh_safety_identity))
        SafetyLine(stringResource(MR.strings.mesh_safety_bluetooth))
        SafetyLine(stringResource(MR.strings.mesh_safety_battery))

        Spacer(Modifier.height(16.dp))
        BackgroundCard(allowed = remember(refresh) { isBackgroundAllowed(context) })

        Spacer(Modifier.height(20.dp))
        when {
            !bluetoothOn -> {
                Text(stringResource(MR.strings.mesh_bt_off), color = MaterialTheme.colors.error)
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = { context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)) },
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(20.dp)
                ) { Text(stringResource(MR.strings.mesh_turn_on_bt)) }
            }
            needsLocationOn && !locationOn -> {
                Text(stringResource(MR.strings.mesh_location_needed), color = MaterialTheme.colors.error)
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = { context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) },
                    modifier = Modifier.fillMaxWidth().height(50.dp),
                    shape = RoundedCornerShape(20.dp)
                ) { Text(stringResource(MR.strings.mesh_turn_on_location)) }
            }
            else -> {
                Button(
                    onClick = { if (hasRequiredPermissions(context)) start() else launcher.launch(meshPermissions()) },
                    modifier = Modifier.fillMaxWidth().height(56.dp),
                    shape = RoundedCornerShape(20.dp),
                    colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.primary)
                ) { Text(stringResource(MR.strings.mesh_start), color = MaterialTheme.colors.onPrimary, fontWeight = FontWeight.Bold) }
            }
        }
        if (permissionsDenied) {
            Spacer(Modifier.height(8.dp))
            Text(
                stringResource(MR.strings.mesh_permission_needed),
                color = MaterialTheme.colors.error,
                style = MaterialTheme.typography.body2
            )
        }
    }
}

@Composable
private fun SafetyLine(text: String) {
    Row(Modifier.padding(vertical = 4.dp)) {
        Icon(painterResource(MR.images.ic_info), contentDescription = null, tint = MaterialTheme.colors.secondary, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, style = MaterialTheme.typography.body2)
    }
}

// ---- Teams ----

@Composable
private fun TeamList(
    teams: List<CrowdMesh.Team>,
    unread: Map<String, Int>,
    onOpen: (String) -> Unit,
    onCreate: () -> Unit,
    onJoin: () -> Unit
) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
        item {
            Text(
                stringResource(MR.strings.mesh_teams_intro),
                style = MaterialTheme.typography.body2,
                color = MaterialTheme.colors.secondary,
                modifier = Modifier.padding(horizontal = DEFAULT_PADDING, vertical = 8.dp)
            )
            Row(Modifier.fillMaxWidth().padding(horizontal = DEFAULT_PADDING, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onCreate, modifier = Modifier.weight(1f).heightIn(min = 52.dp), shape = RoundedCornerShape(16.dp)) {
                    Icon(painterResource(MR.images.ic_add), contentDescription = null, tint = MaterialTheme.colors.onPrimary)
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(MR.strings.mesh_create_team), color = MaterialTheme.colors.onPrimary)
                }
                OutlinedButton(onClick = onJoin, modifier = Modifier.weight(1f).heightIn(min = 52.dp), shape = RoundedCornerShape(16.dp)) {
                    Icon(painterResource(MR.images.ic_qr_code), contentDescription = null, tint = MaterialTheme.colors.primary)
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(MR.strings.mesh_join_with_code))
                }
            }
        }
        if (teams.isEmpty()) {
            item {
                Text(
                    stringResource(MR.strings.mesh_no_team),
                    style = MaterialTheme.typography.body2,
                    fontStyle = FontStyle.Italic,
                    color = MaterialTheme.colors.secondary,
                    modifier = Modifier.padding(DEFAULT_PADDING)
                )
            }
        }
        items(teams, key = { it.id }) { team ->
            ListRow(
                icon = { Icon(painterResource(MR.images.ic_group), contentDescription = null, tint = MaterialTheme.colors.primary) },
                title = team.name,
                detail = stringResource(MR.strings.mesh_encrypted_team),
                unread = unread[CrowdMesh.teamConversation(team.id)] ?: 0,
                onClick = { onOpen(team.id) }
            )
        }
    }
}

@Composable
private fun CreateTeamDialog(onDismiss: () -> Unit, onCreate: (String) -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(MR.strings.mesh_create_team_title)) },
        text = {
            Column {
                Text(stringResource(MR.strings.mesh_create_team_text), style = MaterialTheme.typography.body2)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = name,
                    onValueChange = { if (it.length <= 40) name = it },
                    singleLine = true,
                    placeholder = { Text(stringResource(MR.strings.mesh_team_name_example)) },
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = { TextButton(onClick = { onCreate(name) }, enabled = name.isNotBlank()) { Text(stringResource(MR.strings.mesh_create)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(MR.strings.mesh_cancel)) } }
    )
}

/** Copies a team code, marked sensitive so Android 13+ doesn't show it in clipboard previews. */
private fun copySecret(context: Context, text: String) {
    val clip = ClipData.newPlainText("ChatFort team code", text)
    clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
}

@Composable
private fun TeamCodeDialog(name: String, code: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    val qr = remember(code) { qrCodeBitmap(code, 800, QrCode.ErrorLevel.M) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(MR.strings.mesh_team_code_title).format(name)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    stringResource(MR.strings.mesh_team_code_text),
                    style = MaterialTheme.typography.body2
                )
                Spacer(Modifier.height(12.dp))
                Box(Modifier.fillMaxWidth().background(Color.White).padding(8.dp), contentAlignment = Alignment.Center) {
                    Image(qr, contentDescription = stringResource(MR.strings.mesh_team_code_qr), modifier = Modifier.fillMaxWidth().aspectRatio(1f))
                }
                Spacer(Modifier.height(8.dp))
                SelectionContainer {
                    Text(code, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = MaterialTheme.colors.secondary)
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(MR.strings.mesh_done)) } },
        dismissButton = {
            TextButton(onClick = {
                copySecret(context, code)
                copied = true
            }) { Text(if (copied) stringResource(MR.strings.mesh_copied) else stringResource(MR.strings.mesh_copy_code)) }
        }
    )
}

@Composable
private fun JoinTeam(onJoined: (CrowdMesh.Team) -> Unit) {
    var pasted by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    fun join(code: String): Boolean {
        val team = CrowdMesh.joinTeam(code)
        return if (team != null) {
            onJoined(team)
            true
        } else {
            error = generalGetString(MR.strings.mesh_not_team_code)
            false
        }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        Text(
            stringResource(MR.strings.mesh_join_text),
            style = MaterialTheme.typography.body2,
            modifier = Modifier.padding(horizontal = DEFAULT_PADDING, vertical = 8.dp)
        )
        QRCodeScanner { scanned -> join(scanned) }
        OutlinedTextField(
            value = pasted,
            onValueChange = { pasted = it.trim(); error = null },
            placeholder = { Text("CFTEAM2.…") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = DEFAULT_PADDING)
        )
        error?.let {
            Text(it, color = MaterialTheme.colors.error, style = MaterialTheme.typography.body2, modifier = Modifier.padding(horizontal = DEFAULT_PADDING, vertical = 4.dp))
        }
        Button(
            onClick = { join(pasted) },
            enabled = pasted.isNotBlank(),
            modifier = Modifier.fillMaxWidth().padding(DEFAULT_PADDING).heightIn(min = 52.dp),
            shape = RoundedCornerShape(16.dp)
        ) { Text(stringResource(MR.strings.mesh_join_team), color = MaterialTheme.colors.onPrimary) }
    }
}

// ---- People ----

private fun phones(n: Int) = if (n == 1) generalGetString(MR.strings.mesh_phones_one) else generalGetString(MR.strings.mesh_phones_many).format(n)

private fun people(n: Int) = if (n == 1) generalGetString(MR.strings.mesh_people_one) else generalGetString(MR.strings.mesh_people_many).format(n)

// Approximate: a relaying phone can make someone look closer than they are, so never promise proximity.
private fun distance(hops: Int): String = when {
    hops <= 1 -> generalGetString(MR.strings.mesh_distance_one)
    else -> generalGetString(MR.strings.mesh_distance_many).format(hops)
}

@Composable
private fun PeopleList(
    contacts: List<CrowdMesh.LinkedContact>,
    peers: List<CrowdMesh.Peer>,
    conversations: Set<String>,
    unread: Map<String, Int>,
    onOpenContact: (String) -> Unit,
    onOpen: (String) -> Unit
) {
    val inReach = peers.map { it.peerId }.toSet()
    val away = conversations.filter { it !in inReach }
    val log by CrowdMesh.log.collectAsState()
    var showLog by remember { mutableStateOf(false) }
    var editingNickname by remember { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 8.dp)) {
        item {
            Row(
                Modifier.fillMaxWidth().clickable { editingNickname = true }.padding(horizontal = DEFAULT_PADDING, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(stringResource(MR.strings.mesh_you_appear_as), style = MaterialTheme.typography.body2, color = MaterialTheme.colors.secondary)
                Spacer(Modifier.width(4.dp))
                Text(CrowdMesh.nickname(), style = MaterialTheme.typography.body2, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text(stringResource(MR.strings.mesh_change), style = MaterialTheme.typography.body2, color = MaterialTheme.colors.primary)
            }
        }
        // Wire v3: the profile's ChatFort contacts, recognised on the mesh with no setup.
        item {
            Text(
                stringResource(MR.strings.mesh_your_contacts),
                style = MaterialTheme.typography.caption,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colors.secondary,
                modifier = Modifier.padding(start = DEFAULT_PADDING, top = 8.dp, bottom = 4.dp)
            )
            if (contacts.isEmpty()) {
                Text(
                    stringResource(MR.strings.mesh_contacts_hint),
                    style = MaterialTheme.typography.caption,
                    color = MaterialTheme.colors.secondary,
                    modifier = Modifier.padding(horizontal = DEFAULT_PADDING, vertical = 4.dp)
                )
            }
        }
        items(contacts, key = { "contact:" + it.id }) { c ->
            ListRow(
                icon = { Icon(painterResource(MR.images.ic_person), contentDescription = null, tint = if (c.nearbyHops != null) MaterialTheme.colors.primary else MaterialTheme.colors.secondary) },
                title = c.name,
                detail = c.nearbyHops?.let { stringResource(MR.strings.mesh_contact_in_reach).format(distance(it).lowercase()) } ?: stringResource(MR.strings.mesh_contact_not_seen),
                unread = unread[CrowdMesh.contactConversation(c.id)] ?: 0,
                onClick = { onOpenContact(c.id) }
            )
        }
        item {
            Text(
                stringResource(MR.strings.mesh_people_intro),
                style = MaterialTheme.typography.caption,
                color = MaterialTheme.colors.secondary,
                modifier = Modifier.padding(start = DEFAULT_PADDING, end = DEFAULT_PADDING, top = 16.dp, bottom = 4.dp)
            )
        }
        if (peers.isEmpty()) {
            item {
                Text(
                    stringResource(MR.strings.mesh_nobody),
                    style = MaterialTheme.typography.body2,
                    fontStyle = FontStyle.Italic,
                    color = MaterialTheme.colors.secondary,
                    modifier = Modifier.padding(DEFAULT_PADDING)
                )
            }
        }
        items(peers, key = { it.peerId }) { peer ->
            ListRow(
                icon = { Icon(painterResource(MR.images.ic_person), contentDescription = null, tint = MaterialTheme.colors.primary) },
                title = peer.nickname,
                detail = distance(peer.hops).replaceFirstChar { it.uppercase() },
                unread = unread[CrowdMesh.directConversation(peer.peerId)] ?: 0,
                onClick = { onOpen(peer.peerId) }
            )
        }
        if (away.isNotEmpty()) {
            item {
                Text(
                    stringResource(MR.strings.mesh_earlier_conversations),
                    style = MaterialTheme.typography.caption,
                    color = MaterialTheme.colors.secondary,
                    modifier = Modifier.padding(start = DEFAULT_PADDING, top = 16.dp, bottom = 4.dp)
                )
            }
            items(away, key = { it }) { id ->
                ListRow(
                    icon = { Icon(painterResource(MR.images.ic_person), contentDescription = null, tint = MaterialTheme.colors.secondary) },
                    title = CrowdMesh.peerNickname(id),
                    detail = stringResource(MR.strings.mesh_messages_wait),
                    unread = unread[CrowdMesh.directConversation(id)] ?: 0,
                    onClick = { onOpen(id) }
                )
            }
        }
        item {
            TextButton(onClick = { showLog = !showLog }, modifier = Modifier.padding(horizontal = 8.dp, vertical = 16.dp)) {
                Text(if (showLog) stringResource(MR.strings.mesh_hide_log) else stringResource(MR.strings.mesh_show_log), color = MaterialTheme.colors.secondary)
            }
        }
        if (showLog) {
            items(log.asReversed()) { line ->
                Text(line, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = MaterialTheme.colors.secondary, modifier = Modifier.padding(horizontal = DEFAULT_PADDING))
            }
        }
    }
    if (editingNickname) {
        var value by remember { mutableStateOf(CrowdMesh.nickname()) }
        AlertDialog(
            onDismissRequest = { editingNickname = false },
            title = { Text(stringResource(MR.strings.mesh_nickname_title)) },
            text = {
                Column {
                    OutlinedTextField(value = value, onValueChange = { if (it.length <= 24) value = it }, singleLine = true, modifier = Modifier.fillMaxWidth())
                    Text(stringResource(MR.strings.mesh_nickname_warning), style = MaterialTheme.typography.caption, color = MaterialTheme.colors.error)
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    CrowdMesh.setNickname(value)
                    editingNickname = false
                }, enabled = value.isNotBlank()) { Text(stringResource(MR.strings.mesh_save)) }
            },
            dismissButton = { TextButton(onClick = { editingNickname = false }) { Text(stringResource(MR.strings.mesh_cancel)) } }
        )
    }
}

@Composable
private fun ListRow(icon: @Composable () -> Unit, title: String, detail: String, unread: Int, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).heightIn(min = 56.dp).padding(horizontal = DEFAULT_PADDING, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        icon()
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.body1, fontWeight = FontWeight.Medium, maxLines = 1)
            Text(detail, style = MaterialTheme.typography.caption, color = MaterialTheme.colors.secondary, maxLines = 1)
        }
        if (unread > 0) UnreadBadge(unread)
        else Icon(painterResource(MR.images.ic_lock), contentDescription = stringResource(MR.strings.mesh_encrypted), tint = MaterialTheme.colors.secondary, modifier = Modifier.size(16.dp))
    }
}

// ---- Messages ----

@Composable
private fun ColumnScope.MessageThread(
    messages: List<CrowdMesh.Message>,
    placeholder: String,
    enabled: Boolean = true,
    showDelivery: Boolean = false,
    onSend: (String) -> Unit,
    /** Photos and voice notes (contacts and teams only): type, bytes, duration ms, width, height. */
    onSendMedia: ((MediaType, ByteArray, Int, Int, Int) -> Unit)? = null,
    mediaNote: String? = null
) {
    var input by rememberSaveable { mutableStateOf("") }
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val player = remember { MeshMedia.VoicePlayer(context) }
    var playing by remember { mutableStateOf<String?>(null) }
    DisposableEffect(Unit) { onDispose { player.stop() } }
    val onPlay: (CrowdMesh.Message) -> Unit = { m ->
        if (playing == m.id) {
            player.stop()
            playing = null
        } else {
            val data = CrowdMesh.mediaData(m.id)
            playing = if (data != null && player.play(data) { playing = null }) m.id else null
        }
    }
    // Keyed on the newest message, not the count: the list stops growing at its 500-message cap.
    val newest = messages.lastOrNull()?.let { it.peerId + ":" + it.id }
    LaunchedEffect(newest) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size - 1)
    }
    LazyColumn(
        Modifier.weight(1f).fillMaxWidth().padding(horizontal = 8.dp),
        state = listState,
        contentPadding = PaddingValues(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        if (messages.isEmpty()) {
            item {
                Text(
                    stringResource(MR.strings.mesh_no_messages),
                    style = MaterialTheme.typography.body2,
                    fontStyle = FontStyle.Italic,
                    color = MaterialTheme.colors.secondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 24.dp)
                )
            }
        }
        if (mediaNote != null && onSendMedia != null) {
            item {
                Text(mediaNote, style = MaterialTheme.typography.caption, color = MaterialTheme.colors.secondary, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(4.dp))
            }
        }
        items(messages, key = { it.peerId + ":" + it.id }) { m ->
            if (m.isMine) MineBubble(m, showDelivery, playing == m.id, onPlay) else TheirBubble(m, playing == m.id, onPlay)
        }
    }
    Surface(Modifier.fillMaxWidth(), elevation = 8.dp, color = MaterialTheme.colors.background) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            if (onSendMedia != null && enabled) MediaButtons(onSendMedia)
            OutlinedTextField(
                value = input,
                // What the mesh carries: longer text would be cut on the way.
                onValueChange = { if (it.toByteArray(Charsets.UTF_8).size <= CrowdMesh.MAX_TEXT_BYTES) input = it },
                placeholder = { Text(placeholder) },
                enabled = enabled,
                modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(24.dp),
                maxLines = 4
            )
            Spacer(Modifier.width(8.dp))
            val canSend = enabled && input.isNotBlank()
            IconButton(
                onClick = {
                    if (canSend) {
                        onSend(input.trim())
                        input = ""
                    }
                },
                enabled = canSend
            ) {
                Icon(
                    painterResource(MR.images.ic_arrow_upward),
                    contentDescription = stringResource(MR.strings.mesh_send),
                    tint = if (canSend) MaterialTheme.colors.primary else MaterialTheme.colors.secondary.copy(alpha = 0.5f)
                )
            }
        }
    }
}

@Composable
private fun MineBubble(m: CrowdMesh.Message, showDelivery: Boolean, playing: Boolean, onPlay: (CrowdMesh.Message) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(start = 48.dp), horizontalAlignment = Alignment.End) {
        Box(
            Modifier.clip(RoundedCornerShape(16.dp, 16.dp, 4.dp, 16.dp))
                .background(MaterialTheme.colors.primary.copy(alpha = 0.15f))
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            if (m.media != null) MediaContent(m, playing, onPlay)
            else Text(m.text, style = MaterialTheme.typography.body1, color = MaterialTheme.colors.onBackground)
        }
        val delivery = when {
            !showDelivery -> ""
            m.delivered -> " · " + stringResource(MR.strings.mesh_delivered)
            m.viaInternet -> " · " + stringResource(MR.strings.mesh_sent_via_internet)
            else -> " · " + stringResource(MR.strings.mesh_on_its_way)
        }
        Text(
            formatTime(m.timestamp) + delivery,
            style = MaterialTheme.typography.caption,
            color = if (m.delivered) MaterialTheme.colors.primary else MaterialTheme.colors.secondary.copy(alpha = 0.6f),
            modifier = Modifier.padding(top = 2.dp, end = 4.dp)
        )
    }
}

@Composable
private fun TheirBubble(m: CrowdMesh.Message, playing: Boolean, onPlay: (CrowdMesh.Message) -> Unit) {
    Column(Modifier.fillMaxWidth().padding(end = 48.dp), horizontalAlignment = Alignment.Start) {
        // Contacts' chats have no nickname line: the screen is already theirs.
        if (m.nickname.isNotBlank()) Text(
            m.nickname,
            style = MaterialTheme.typography.caption,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colors.primary,
            modifier = Modifier.padding(start = 12.dp, bottom = 2.dp)
        )
        Box(
            Modifier.clip(RoundedCornerShape(16.dp, 16.dp, 16.dp, 4.dp))
                .background(MaterialTheme.colors.surface)
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            if (m.media != null) MediaContent(m, playing, onPlay)
            else Text(m.text, style = MaterialTheme.typography.body1, color = MaterialTheme.colors.onSurface)
        }
        Text(
            formatTime(m.timestamp) + " · " + if (m.hops <= 1) stringResource(MR.strings.mesh_hops_one) else stringResource(MR.strings.mesh_hops_many).format(m.hops),
            style = MaterialTheme.typography.caption,
            color = MaterialTheme.colors.secondary.copy(alpha = 0.6f),
            modifier = Modifier.padding(top = 2.dp, start = 12.dp)
        )
    }
}

private fun formatTime(timestamp: Long): String =
    SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timestamp))

// ---- Photos and voice notes (wire v3) ----

/** Photo (camera or gallery) and hold-to-record voice. */
@Composable
private fun MediaButtons(onSendMedia: (MediaType, ByteArray, Int, Int, Int) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var preparing by remember { mutableStateOf(false) }
    var cameraFile by remember { mutableStateOf<File?>(null) }

    fun sendPhoto(uri: Uri, cleanup: File? = null) {
        preparing = true
        scope.launch {
            val photo = withContext(Dispatchers.IO) { MeshMedia.preparePhoto(context, uri).also { cleanup?.delete() } }
            preparing = false
            if (photo == null) android.widget.Toast.makeText(context, generalGetString(MR.strings.mesh_photo_failed), android.widget.Toast.LENGTH_LONG).show()
            else onSendMedia(MediaType.PHOTO, photo.data, 0, photo.width, photo.height)
        }
    }

    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> if (uri != null) sendPhoto(uri) }
    val takePhoto = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        val f = cameraFile
        cameraFile = null
        if (ok && f != null && f.length() > 0) sendPhoto(Uri.fromFile(f), f) else f?.delete()
    }
    fun openCamera() {
        val (file, uri) = MeshMedia.cameraTarget(context)
        cameraFile = file
        try { takePhoto.launch(uri) } catch (_: ActivityNotFoundException) { cameraFile = null }
    }
    // The app declares CAMERA, so the camera app can only be used once it is granted.
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> if (granted) openCamera() }

    Box {
        IconButton(onClick = { menu = true }, enabled = !preparing) {
            if (preparing) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            else Icon(painterResource(MR.images.ic_image), contentDescription = stringResource(MR.strings.mesh_send_photo), tint = MaterialTheme.colors.primary)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(onClick = {
                menu = false
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) openCamera()
                else cameraPermission.launch(Manifest.permission.CAMERA)
            }) {
                Icon(painterResource(MR.images.ic_photo_camera), contentDescription = null, tint = MaterialTheme.colors.primary)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(MR.strings.mesh_take_photo))
            }
            DropdownMenuItem(onClick = {
                menu = false
                pickPhoto.launch(androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }) {
                Icon(painterResource(MR.images.ic_image), contentDescription = null, tint = MaterialTheme.colors.primary)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(MR.strings.mesh_choose_photo))
            }
        }
    }
    VoiceButton(onSendMedia)
}

@Composable
private fun VoiceButton(onSendMedia: (MediaType, ByteArray, Int, Int, Int) -> Unit) {
    val context = LocalContext.current
    var recorder by remember { mutableStateOf<MeshMedia.VoiceRecorder?>(null) }
    var elapsed by remember { mutableStateOf(0L) }
    val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }

    fun finish(send: Boolean) {
        val r = recorder ?: return
        recorder = null
        if (!send) {
            r.cancel()
            return
        }
        val result = r.stop()
        if (result == null) android.widget.Toast.makeText(context, generalGetString(MR.strings.mesh_voice_failed), android.widget.Toast.LENGTH_SHORT).show()
        else onSendMedia(MediaType.VOICE, result.first, result.second, 0, 0)
    }
    // Shows the time, and sends by itself at the 30-second limit.
    LaunchedEffect(recorder) {
        while (recorder != null) {
            elapsed = recorder?.elapsedMs ?: 0
            if (elapsed >= MeshMedia.MAX_VOICE_MS) finish(send = true)
            delay(200)
        }
    }
    DisposableEffect(Unit) { onDispose { recorder?.cancel() } }

    if (recorder != null) {
        Popup30sHint(elapsed)
    }
    Box(
        Modifier.size(48.dp).pointerInput(Unit) {
            detectTapGestures(onPress = {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    android.widget.Toast.makeText(context, generalGetString(MR.strings.mesh_mic_needed), android.widget.Toast.LENGTH_SHORT).show()
                    micPermission.launch(Manifest.permission.RECORD_AUDIO)
                    return@detectTapGestures
                }
                val r = MeshMedia.VoiceRecorder(context)
                if (!r.start()) {
                    android.widget.Toast.makeText(context, generalGetString(MR.strings.mesh_voice_failed), android.widget.Toast.LENGTH_SHORT).show()
                    return@detectTapGestures
                }
                recorder = r
                val released = tryAwaitRelease()
                if (recorder === r) finish(send = released)
            })
        },
        contentAlignment = Alignment.Center
    ) {
        Icon(
            painterResource(if (recorder != null) MR.images.ic_mic_filled else MR.images.ic_mic),
            contentDescription = stringResource(MR.strings.mesh_hold_to_record),
            tint = if (recorder != null) MaterialTheme.colors.error else MaterialTheme.colors.primary
        )
    }
}

@Composable
private fun Popup30sHint(elapsedMs: Long) {
    val seconds = (elapsedMs / 1000).toInt()
    androidx.compose.ui.window.Popup(alignment = Alignment.BottomCenter, offset = androidx.compose.ui.unit.IntOffset(0, -180)) {
        Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colors.error, elevation = 6.dp) {
            Text(
                stringResource(MR.strings.mesh_recording).format("0:%02d".format(seconds)),
                color = Color.White,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp)
            )
        }
    }
}

@Composable
private fun MediaContent(m: CrowdMesh.Message, playing: Boolean, onPlay: (CrowdMesh.Message) -> Unit) {
    val media = m.media ?: return
    Column {
        if (!media.complete) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
                Column {
                    Text(stringResource(if (media.type == MediaType.PHOTO) MR.strings.mesh_photo else MR.strings.mesh_voice_note), fontWeight = FontWeight.Medium)
                    Text(stringResource(MR.strings.mesh_receiving).format(media.received, media.total), style = MaterialTheme.typography.caption, color = MaterialTheme.colors.secondary)
                }
            }
        } else when (media.type) {
            MediaType.PHOTO -> MeshPhoto(m)
            MediaType.VOICE -> Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { onPlay(m) }) {
                    Icon(
                        painterResource(if (playing) MR.images.ic_pause_filled else MR.images.ic_play_arrow_filled),
                        contentDescription = stringResource(if (playing) MR.strings.mesh_pause else MR.strings.mesh_play),
                        tint = MaterialTheme.colors.primary
                    )
                }
                Text(stringResource(MR.strings.mesh_voice_note) + " · " + "%d:%02d".format(media.durationMs / 60_000, media.durationMs / 1000 % 60))
            }
        }
        if (media.caption.isNotBlank()) Text(media.caption, style = MaterialTheme.typography.body1, modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
private fun MeshPhoto(m: CrowdMesh.Message) {
    val bitmap by produceState<ImageBitmap?>(null, m.id) {
        value = withContext(Dispatchers.IO) { CrowdMesh.mediaData(m.id)?.let { MeshMedia.decodeForDisplay(it)?.asImageBitmap() } }
    }
    var full by remember { mutableStateOf(false) }
    val b = bitmap
    if (b == null) {
        Box(Modifier.size(200.dp, 150.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp) }
        return
    }
    Image(
        b,
        contentDescription = stringResource(MR.strings.mesh_photo),
        contentScale = ContentScale.Fit,
        modifier = Modifier.widthIn(max = 240.dp).heightIn(max = 320.dp).clip(RoundedCornerShape(10.dp)).clickable { full = true }
    )
    if (full) {
        Dialog(onDismissRequest = { full = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxSize().background(Color.Black).clickable { full = false }, contentAlignment = Alignment.Center) {
                Image(b, contentDescription = stringResource(MR.strings.mesh_photo), contentScale = ContentScale.Fit, modifier = Modifier.fillMaxWidth())
                IconButton(onClick = { full = false }, modifier = Modifier.align(Alignment.TopEnd).padding(8.dp)) {
                    Icon(painterResource(MR.images.ic_close), contentDescription = stringResource(MR.strings.mesh_close), tint = Color.White)
                }
            }
        }
    }
}
