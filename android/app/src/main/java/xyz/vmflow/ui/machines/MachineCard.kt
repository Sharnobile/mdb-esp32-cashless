package xyz.vmflow.ui.machines

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.ui.components.StatusChip
import xyz.vmflow.ui.components.StockHealthBar
import java.text.NumberFormat
import java.util.Locale

@Composable
fun MachineCard(
    machineStats: MachineWithStats,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val currencyFormat = NumberFormat.getCurrencyInstance(Locale.GERMANY).apply {
        currency = java.util.Currency.getInstance("EUR")
    }

    Card(
        onClick = onClick,
        modifier = modifier.fillMaxWidth(),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            // Top row: Name + Status
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = machineStats.machine.displayName,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Spacer(modifier = Modifier.width(8.dp))
                StatusChip(isOnline = machineStats.machine.isOnline)
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Revenue row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text(
                        text = "Today",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = currencyFormat.format(machineStats.todayRevenue),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                Column {
                    Text(
                        text = "Sales",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "${machineStats.todaySalesCount}",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
                Column {
                    Text(
                        text = "Yesterday",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = currencyFormat.format(machineStats.yesterdayRevenue),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Stock health bar
            if (machineStats.trays.isNotEmpty()) {
                StockHealthBar(trays = machineStats.trays)
                Spacer(modifier = Modifier.height(8.dp))
            }

            // Last sale + pax
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                machineStats.lastSaleAt?.let { dateStr ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.Schedule,
                            contentDescription = null,
                            modifier = Modifier.height(14.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(
                            text = formatTimeAgo(dateStr),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                if (machineStats.paxCount > 0) {
                    Text(
                        text = "${machineStats.paxCount} visitors",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

private fun formatTimeAgo(isoString: String): String {
    return try {
        val instant = kotlinx.datetime.Instant.parse(isoString)
        val now = kotlinx.datetime.Clock.System.now()
        val diff = now - instant
        when {
            diff.inWholeMinutes < 1 -> "Just now"
            diff.inWholeMinutes < 60 -> "${diff.inWholeMinutes}m ago"
            diff.inWholeHours < 24 -> "${diff.inWholeHours}h ago"
            diff.inWholeDays < 7 -> "${diff.inWholeDays}d ago"
            else -> isoString.take(10)
        }
    } catch (_: Exception) {
        isoString.take(16)
    }
}
