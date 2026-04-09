package xyz.vmflow.ui.trays

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import xyz.vmflow.models.Product
import xyz.vmflow.models.Tray

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrayEditDialog(
    tray: Tray?,
    products: List<Product>,
    machineId: String,
    onDismiss: () -> Unit,
    onSave: (itemNumber: Int, productId: String?, capacity: Int, currentStock: Int, minStock: Int?, fillWhenBelow: Int?) -> Unit
) {
    val isEditing = tray != null
    var itemNumber by remember { mutableIntStateOf(tray?.itemNumber ?: 1) }
    var selectedProductId by remember { mutableStateOf(tray?.productId) }
    var capacity by remember { mutableIntStateOf(tray?.capacity ?: 10) }
    var currentStock by remember { mutableIntStateOf(tray?.currentStock ?: 0) }
    var minStock by remember { mutableIntStateOf(tray?.minStock ?: 2) }
    var fillWhenBelow by remember { mutableIntStateOf(tray?.fillWhenBelow ?: 3) }
    var productDropdownExpanded by remember { mutableStateOf(false) }

    val selectedProduct = products.find { it.id == selectedProductId }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (isEditing) "Edit Tray #${tray?.itemNumber}" else "Add Tray") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedTextField(
                    value = itemNumber.toString(),
                    onValueChange = { itemNumber = it.toIntOrNull() ?: itemNumber },
                    label = { Text("Slot Number") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                ExposedDropdownMenuBox(
                    expanded = productDropdownExpanded,
                    onExpandedChange = { productDropdownExpanded = it }
                ) {
                    OutlinedTextField(
                        value = selectedProduct?.name ?: "No product",
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Product") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = productDropdownExpanded) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .menuAnchor(MenuAnchorType.PrimaryNotEditable)
                    )
                    ExposedDropdownMenu(
                        expanded = productDropdownExpanded,
                        onDismissRequest = { productDropdownExpanded = false }
                    ) {
                        DropdownMenuItem(
                            text = { Text("No product") },
                            onClick = {
                                selectedProductId = null
                                productDropdownExpanded = false
                            }
                        )
                        products.forEach { product ->
                            DropdownMenuItem(
                                text = { Text(product.name ?: "Unnamed") },
                                onClick = {
                                    selectedProductId = product.id
                                    productDropdownExpanded = false
                                }
                            )
                        }
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    OutlinedTextField(
                        value = capacity.toString(),
                        onValueChange = { capacity = it.toIntOrNull() ?: capacity },
                        label = { Text("Capacity") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    OutlinedTextField(
                        value = currentStock.toString(),
                        onValueChange = { currentStock = it.toIntOrNull() ?: currentStock },
                        label = { Text("Stock") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    OutlinedTextField(
                        value = minStock.toString(),
                        onValueChange = { minStock = it.toIntOrNull() ?: minStock },
                        label = { Text("Min Stock") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    OutlinedTextField(
                        value = fillWhenBelow.toString(),
                        onValueChange = { fillWhenBelow = it.toIntOrNull() ?: fillWhenBelow },
                        label = { Text("Fill Below") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    onSave(
                        itemNumber,
                        selectedProductId,
                        capacity,
                        currentStock.coerceAtMost(capacity),
                        minStock,
                        fillWhenBelow
                    )
                }
            ) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}

@Composable
fun BatchAddDialog(
    machineId: String,
    onDismiss: () -> Unit,
    onSave: (startSlot: Int, count: Int, capacity: Int) -> Unit
) {
    var startSlot by remember { mutableIntStateOf(1) }
    var count by remember { mutableIntStateOf(5) }
    var capacity by remember { mutableIntStateOf(10) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Batch Add Trays") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    text = "Add multiple trays with sequential slot numbers.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                OutlinedTextField(
                    value = startSlot.toString(),
                    onValueChange = { startSlot = it.toIntOrNull() ?: startSlot },
                    label = { Text("Starting Slot") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = count.toString(),
                    onValueChange = { count = it.toIntOrNull() ?: count },
                    label = { Text("Number of Trays") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = capacity.toString(),
                    onValueChange = { capacity = it.toIntOrNull() ?: capacity },
                    label = { Text("Capacity (each)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "This will create slots $startSlot through ${startSlot + count - 1}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(startSlot, count, capacity) },
                enabled = count > 0 && capacity > 0
            ) {
                Text("Add ${count} Trays")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
