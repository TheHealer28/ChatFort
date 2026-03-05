package chat.simplex.app.nearby

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.chatlist.LocalTabBarHeight

/**
 * Shows a live list of nearby Inqalaab users discovered via BLE.
 * Tap a person to send a connection request; accept incoming requests.
 */
@Composable
fun NearbyPeopleView(onBack: () -> Unit) {
    val people = NearbyUiState.discoveredPeople
    val incoming = NearbyUiState.incomingRequest.value
    val outgoing = NearbyUiState.outgoingRequest.value

    BackHandler { onBack() }

    // Pulsing animation for the scanning indicator
    val infiniteTransition = rememberInfiniteTransition()
    val alpha by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000),
            repeatMode = RepeatMode.Reverse
        )
    )

    val tabBarHeight = LocalTabBarHeight.current
    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(horizontal = DEFAULT_PADDING)
            .padding(top = 8.dp, bottom = tabBarHeight)
    ) {
        // Back button
        Row(Modifier.fillMaxWidth()) {
            TextButton(onClick = onBack) {
                Text("\u2190 Back", color = MaterialTheme.colors.primary)
            }
        }

        Spacer(Modifier.height(8.dp))

        Text(
            "Find People Nearby",
            style = MaterialTheme.typography.h2,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colors.primary
        )

        Spacer(Modifier.height(4.dp))

        Text(
            "Searching for Inqalaab users near you\u2026",
            style = MaterialTheme.typography.body2,
            color = MaterialTheme.colors.secondary.copy(alpha = alpha)
        )

        Spacer(Modifier.height(16.dp))

        // Incoming connection request banner
        if (incoming != null && outgoing == null) {
            Card(
                Modifier.fillMaxWidth(),
                backgroundColor = MaterialTheme.colors.primary.copy(alpha = 0.1f),
                shape = RoundedCornerShape(12.dp),
                elevation = 0.dp
            ) {
                Column(Modifier.padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "${incoming.name} wants to connect",
                        style = MaterialTheme.typography.body1,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colors.onBackground
                    )
                    Spacer(Modifier.height(12.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedButton(
                            onClick = { NearbyUiState.incomingRequest.value = null },
                            shape = RoundedCornerShape(20.dp)
                        ) {
                            Text("Decline")
                        }
                        Button(
                            onClick = { NearbyManager.acceptDirectConnection(incoming) },
                            colors = ButtonDefaults.buttonColors(backgroundColor = MaterialTheme.colors.primary),
                            shape = RoundedCornerShape(20.dp)
                        ) {
                            Text("Accept", color = MaterialTheme.colors.onPrimary, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }

        // Waiting for acceptance
        if (outgoing != null) {
            Card(
                Modifier.fillMaxWidth(),
                backgroundColor = MaterialTheme.colors.surface,
                shape = RoundedCornerShape(12.dp),
                elevation = 2.dp
            ) {
                Row(
                    Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    CircularProgressIndicator(Modifier.size(24.dp), color = MaterialTheme.colors.primary, strokeWidth = 2.dp)
                    Text(
                        "Waiting for ${outgoing.name} to accept\u2026",
                        style = MaterialTheme.typography.body1,
                        color = MaterialTheme.colors.secondary
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = { NearbyManager.cancelDirectRequest() }) {
                Text("Cancel", color = MaterialTheme.colors.error)
            }
            Spacer(Modifier.height(16.dp))
        }

        // People list
        if (people.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Column(
                    Modifier.padding(horizontal = DEFAULT_PADDING),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    CircularProgressIndicator(
                        Modifier.size(40.dp),
                        color = MaterialTheme.colors.primary.copy(alpha = alpha),
                        strokeWidth = 3.dp
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        "Scanning for people\u2026",
                        style = MaterialTheme.typography.h6,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colors.onBackground
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        "Troubleshooting",
                        style = MaterialTheme.typography.body2,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colors.secondary
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "\u2022 Both devices need Bluetooth turned on\n\u2022 Both devices need Location Services enabled\n\u2022 The other person must also have Nearby open\n\u2022 Stay within ~30 feet of each other",
                        style = MaterialTheme.typography.body2,
                        color = MaterialTheme.colors.secondary.copy(alpha = 0.7f),
                        textAlign = TextAlign.Start
                    )
                }
            }
        } else {
            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(people.toList()) { person ->
                    PersonCard(person, enabled = outgoing == null) {
                        NearbyManager.requestDirectConnection(person)
                    }
                }
            }
        }
    }
}

@Composable
private fun PersonCard(person: DiscoveredPerson, enabled: Boolean, onClick: () -> Unit) {
    Card(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        elevation = 2.dp
    ) {
        Row(
            Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Avatar circle with first letter
            Box(
                Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colors.primary.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    person.name.firstOrNull()?.uppercase() ?: "?",
                    style = MaterialTheme.typography.h3,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colors.primary
                )
            }

            Column(Modifier.weight(1f)) {
                Text(
                    person.name,
                    style = MaterialTheme.typography.body1,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colors.onSurface
                )
                Text(
                    "Tap to connect",
                    style = MaterialTheme.typography.caption,
                    color = MaterialTheme.colors.secondary
                )
            }
        }
    }
}
