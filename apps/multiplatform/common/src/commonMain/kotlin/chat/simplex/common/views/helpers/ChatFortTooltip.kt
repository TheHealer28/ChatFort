package chat.simplex.common.views.helpers

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import chat.simplex.common.platform.appPlatform
import chat.simplex.res.MR

@Composable
fun ChatFortTooltipOverlay(
    show: Boolean,
    targetBounds: Rect?,
    message: String,
    onDismiss: () -> Unit
) {
    if (!show || targetBounds == null || !appPlatform.isAndroid) return

    val density = LocalDensity.current
    val padding = with(density) { 8.dp.toPx() }
    val cornerRadius = with(density) { 12.dp.toPx() }
    BoxWithConstraints(
        Modifier
            .fillMaxSize()
            .zIndex(100f)
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() }
            ) { onDismiss() }
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawBehind {
                drawRect(Color.Black.copy(alpha = 0.7f))
                drawRoundRect(
                    color = Color.Transparent,
                    topLeft = Offset(
                        targetBounds.left - padding,
                        targetBounds.top - padding
                    ),
                    size = Size(
                        targetBounds.width + padding * 2,
                        targetBounds.height + padding * 2
                    ),
                    cornerRadius = CornerRadius(cornerRadius),
                    blendMode = BlendMode.Clear
                )
            }
    ) {
        val verticalPadding = 24.dp
        val estimatedCardHeight = 132.dp
        val gap = 16.dp
        val targetTop = with(density) { targetBounds.top.toDp() }
        val targetBottom = with(density) { targetBounds.bottom.toDp() }
        val placeBelow = targetBottom + gap + estimatedCardHeight <= maxHeight - verticalPadding
        val tooltipTop: Dp = if (placeBelow) {
            targetBottom + gap
        } else {
            (targetTop - estimatedCardHeight - gap).coerceAtLeast(verticalPadding)
        }

        Column(
            Modifier
                .align(Alignment.TopCenter)
                .padding(horizontal = 24.dp)
                .offset(y = tooltipTop)
                .fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(
                Modifier
                    .widthIn(max = 360.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color.White)
                    .clickable(
                        indication = null,
                        interactionSource = remember { MutableInteractionSource() }
                    ) {}
                    .padding(horizontal = 20.dp, vertical = 16.dp)
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        message,
                        color = Color.Black,
                        style = MaterialTheme.typography.body1,
                        fontWeight = FontWeight.Medium,
                        textAlign = TextAlign.Center
                    )
                    Spacer(Modifier.height(12.dp))
                    TextButton(onClick = onDismiss) {
                        Text(
                            generalGetString(MR.strings.inq_tooltip_got_it),
                            color = MaterialTheme.colors.primary,
                            style = MaterialTheme.typography.button,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        }
    }
}
