package xyz.vmflow.ui.products

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.launch
import xyz.vmflow.R
import xyz.vmflow.data.ProductBarcode
import xyz.vmflow.data.ProductEditLogic
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.components.QrScannerSheet
import xyz.vmflow.ui.warehouse.WAREHOUSE_BARCODE_FORMATS

/**
 * Create / edit a product: photo (camera or gallery), name, price, category,
 * barcodes, discontinued, delete. Ported from iOS `ProductEditSheet.swift`.
 *
 * Built for the "standing in front of a new product" case: a photo and
 * barcodes can be added before the product exists — they are kept here and
 * written right after the insert ([ProductsViewModel.saveProduct]). For an
 * existing product they are written immediately, like on iOS.
 *
 * [productId] null = new product. [initialBarcode] pre-fills a new product
 * from a scan that matched nothing (warehouse intake); the name is then
 * suggested from Open Food Facts. [onSaved] gets the product id.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProductEditSheet(
    viewModel: ProductsViewModel,
    productId: String?,
    onDismiss: () -> Unit,
    onSaved: (String) -> Unit = {},
    initialBarcode: String? = null,
) {
    val uiState by viewModel.uiState.collectAsState()
    val product = productId?.let { id -> uiState.products.firstOrNull { it.id == id } }
    val isNew = productId == null
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var name by remember { mutableStateOf(product?.name.orEmpty()) }
    var priceText by remember { mutableStateOf(ProductEditLogic.formatPrice(product?.sellprice)) }
    var categoryId by remember { mutableStateOf(product?.category) }
    var discontinued by remember { mutableStateOf(product?.discontinued ?: false) }

    /** Photo taken / picked in this sheet — the preview; for a new product also the pending upload. */
    var localPreview by remember { mutableStateOf<Bitmap?>(null) }
    var pendingPhoto by remember { mutableStateOf<ByteArray?>(null) }
    var isProcessingPhoto by remember { mutableStateOf(false) }

    var barcodes by remember { mutableStateOf<List<ProductBarcode>>(emptyList()) }
    val pendingBarcodes = remember { mutableStateListOf<String>() }
    var manualBarcode by remember { mutableStateOf("") }
    var showScanner by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }

    val photoFailed = stringResource(R.string.product_photo_failed)
    val cameraDenied = stringResource(R.string.product_camera_denied)
    val duplicateTemplate = stringResource(R.string.product_barcode_duplicate)

    LaunchedEffect(productId) {
        if (productId != null) viewModel.loadBarcodes(productId) { barcodes = it }
    }

    fun usePhoto(uri: Uri) {
        viewModel.clearError()
        scope.launch {
            isProcessingPhoto = true
            val photo = loadProductPhoto(context, uri)
            isProcessingPhoto = false
            if (photo == null) {
                viewModel.reportError(photoFailed)
                return@launch
            }
            localPreview = photo.preview
            if (productId == null) pendingPhoto = photo.jpeg else viewModel.uploadImage(productId, photo.jpeg)
        }
    }

    var captureUri by remember { mutableStateOf<Uri?>(null) }
    val takePicture = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val uri = captureUri
        if (uri != null && capturedPhotoAvailable(context, saved)) usePhoto(uri)
    }
    fun launchCamera() {
        val uri = productCaptureUri(context)
        captureUri = uri
        takePicture.launch(uri)
    }
    // The app declares CAMERA (barcode scanner), and then Android only lets it
    // fire the camera-app intent once that permission is actually granted.
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchCamera() else viewModel.reportError(cameraDenied)
    }
    val pickPhoto = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) usePhoto(uri)
    }

    fun addBarcode(raw: String) {
        viewModel.clearError()
        val code = raw.trim()
        if (code.isEmpty()) return
        if (barcodes.any { it.barcode == code } || code in pendingBarcodes) {
            viewModel.reportError(duplicateTemplate.format(code))
            return
        }
        if (productId != null) viewModel.addBarcode(productId, code) { barcodes = it } else pendingBarcodes.add(code)
        // Same as iOS: suggest a name from the barcode, never over a typed one.
        if (name.isBlank()) viewModel.lookupName(code) { suggested -> if (name.isBlank()) name = suggested }
    }

    LaunchedEffect(initialBarcode) {
        if (isNew && initialBarcode != null && initialBarcode !in pendingBarcodes) addBarcode(initialBarcode)
    }

    val priceValid = ProductEditLogic.isPriceValid(priceText)
    val canSave = name.isNotBlank() && priceValid && !uiState.isSaving && !isProcessingPhoto
    val busyWithImage = uiState.isUploadingImage || isProcessingPhoto
    val hasImage = localPreview != null || product?.imagePath != null

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .imePadding()
                .padding(horizontal = 24.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(if (isNew) R.string.product_new_title else R.string.product_edit_title),
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.weight(1f)
                )
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.action_cancel)) }
                Button(
                    enabled = canSave,
                    onClick = {
                        viewModel.saveProduct(
                            existing = product,
                            name = name.trim(),
                            sellprice = ProductEditLogic.parsePrice(priceText),
                            categoryId = categoryId,
                            discontinued = discontinued,
                            pendingPhoto = pendingPhoto,
                            pendingBarcodes = pendingBarcodes.toList()
                        ) { savedId ->
                            if (savedId != null) {
                                onSaved(savedId)
                                onDismiss()
                            }
                        }
                    }
                ) {
                    if (uiState.isSaving) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.action_save))
                    }
                }
            }

            // The list's snackbar sits behind this sheet, so errors show here.
            uiState.error?.let { message ->
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error
                )
            }

            // ── Image ──
            Row(verticalAlignment = Alignment.CenterVertically) {
                val preview = localPreview
                if (preview != null) {
                    Image(
                        bitmap = preview.asImageBitmap(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(96.dp)
                            .clip(RoundedCornerShape(12.dp))
                    )
                } else {
                    ProductImage(
                        imagePath = product?.imagePath,
                        contentDescription = null,
                        size = 96.dp,
                        cacheKey = product?.id?.let { uiState.imageVersions[it] }
                    )
                }
                Spacer(Modifier.width(16.dp))
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Button(
                        enabled = !busyWithImage,
                        onClick = {
                            val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                                PackageManager.PERMISSION_GRANTED
                            if (granted) launchCamera() else cameraPermission.launch(Manifest.permission.CAMERA)
                        }
                    ) {
                        Icon(Icons.Default.PhotoCamera, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.product_photo_take))
                    }
                    OutlinedButton(
                        enabled = !busyWithImage,
                        onClick = {
                            pickPhoto.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        }
                    ) {
                        Icon(Icons.Default.PhotoLibrary, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.product_photo_pick))
                    }
                    if (hasImage) {
                        TextButton(
                            enabled = !busyWithImage,
                            onClick = {
                                if (isNew) {
                                    localPreview = null
                                    pendingPhoto = null
                                } else if (product != null) {
                                    localPreview = null
                                    viewModel.deleteImage(product)
                                }
                            }
                        ) {
                            Text(stringResource(R.string.product_photo_remove), color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
            if (busyWithImage) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.product_photo_uploading), style = MaterialTheme.typography.bodySmall)
                }
            }

            // ── Details ──
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(stringResource(R.string.product_name)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = priceText,
                onValueChange = { priceText = it },
                label = { Text(stringResource(R.string.product_price)) },
                singleLine = true,
                isError = !priceValid,
                supportingText = {
                    if (!priceValid) Text(stringResource(R.string.product_price_invalid))
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth()
            )
            CategoryPicker(
                categories = uiState.categories.map { it.id to (it.name ?: it.id) },
                selectedId = categoryId,
                onSelect = { categoryId = it }
            )

            // ── Barcodes ──
            HorizontalDivider()
            Text(stringResource(R.string.product_barcodes), style = MaterialTheme.typography.titleMedium)
            barcodes.forEach { bc ->
                BarcodeRow(code = bc.barcode, format = bc.format) {
                    viewModel.deleteBarcode(bc) { barcodes = barcodes.filterNot { it.id == bc.id } }
                }
            }
            pendingBarcodes.forEach { code ->
                BarcodeRow(code = code, format = ProductEditLogic.detectBarcodeFormat(code)) {
                    pendingBarcodes.remove(code)
                }
            }
            OutlinedButton(onClick = { showScanner = true }) {
                Icon(Icons.Default.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.product_barcode_scan))
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = manualBarcode,
                    onValueChange = { manualBarcode = it },
                    label = { Text(stringResource(R.string.product_barcode_manual)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f)
                )
                Spacer(Modifier.width(8.dp))
                TextButton(
                    enabled = manualBarcode.isNotBlank(),
                    onClick = {
                        addBarcode(manualBarcode)
                        manualBarcode = ""
                    }
                ) { Text(stringResource(R.string.product_barcode_add)) }
            }

            // ── Status ──
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.product_discontinued), modifier = Modifier.weight(1f))
                Switch(checked = discontinued, onCheckedChange = { discontinued = it })
            }

            if (product != null) {
                TextButton(onClick = { showDeleteConfirm = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Default.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.product_delete), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }

    if (showScanner) {
        QrScannerSheet(
            onResult = { code ->
                showScanner = false
                addBarcode(code)
            },
            onDismiss = { showScanner = false },
            formats = WAREHOUSE_BARCODE_FORMATS,
            title = stringResource(R.string.product_barcode_scan),
            hint = stringResource(R.string.warehouse_intake_scan_hint)
        )
    }

    if (showDeleteConfirm && product != null) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text(stringResource(R.string.product_delete)) },
            text = { Text(stringResource(R.string.product_delete_confirm, product.name.orEmpty())) },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteConfirm = false
                    viewModel.deleteProduct(product) { onDismiss() }
                }) { Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text(stringResource(R.string.action_cancel)) }
            }
        )
    }
}

@Composable
private fun BarcodeRow(code: String, format: String?, onDelete: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.weight(1f)) {
            Text(code, style = MaterialTheme.typography.bodyLarge)
            if (format != null) {
                Text(format, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        IconButton(onClick = onDelete) {
            Icon(Icons.Default.Delete, contentDescription = stringResource(R.string.action_delete))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CategoryPicker(
    categories: List<Pair<String, String>>,
    selectedId: String?,
    onSelect: (String?) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    val noneLabel = stringResource(R.string.product_category_none)
    val selectedLabel = categories.firstOrNull { it.first == selectedId }?.second ?: noneLabel

    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text(stringResource(R.string.product_category)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor(MenuAnchorType.PrimaryNotEditable)
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text(noneLabel) }, onClick = {
                onSelect(null)
                expanded = false
            })
            categories.forEach { (id, label) ->
                DropdownMenuItem(text = { Text(label) }, onClick = {
                    onSelect(id)
                    expanded = false
                })
            }
        }
    }
}
