package xyz.vmflow.ui.products

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import xyz.vmflow.R
import xyz.vmflow.models.Product
import xyz.vmflow.ui.components.ProductImage
import xyz.vmflow.ui.deals.formatEuro

/** Sentinel for "the sheet is open for a new product". */
private const val NEW_PRODUCT = ""

/**
 * Product catalogue: search, list, add / edit via [ProductEditSheet].
 * Mirrors iOS `ProductsView` (list part; categories, purchase prices and the
 * web image search stay on web / iOS for now).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProductsScreen(viewModel: ProductsViewModel = viewModel()) {
    val uiState by viewModel.uiState.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }
    /** null = no sheet, [NEW_PRODUCT] = new product, else the product id. */
    var sheetProductId by remember { mutableStateOf<String?>(null) }

    // The view model outlives tab switches, so without this a product edited
    // on another device (e.g. a photo taken on the iPhone) never showed up.
    LaunchedEffect(Unit) { viewModel.refresh() }

    // While the sheet is open it shows the error itself (this snackbar would be behind it).
    LaunchedEffect(uiState.error, sheetProductId) {
        if (sheetProductId != null) return@LaunchedEffect
        uiState.error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearError()
        }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text(stringResource(R.string.nav_products)) }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { sheetProductId = NEW_PRODUCT },
                icon = { Icon(Icons.Default.Add, contentDescription = null) },
                text = { Text(stringResource(R.string.products_add)) }
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            OutlinedTextField(
                value = uiState.searchText,
                onValueChange = viewModel::updateSearch,
                placeholder = { Text(stringResource(R.string.products_search)) },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
            )
            FilterChip(
                selected = uiState.showDiscontinued,
                onClick = viewModel::toggleShowDiscontinued,
                label = { Text(stringResource(R.string.products_show_discontinued)) },
                modifier = Modifier.padding(horizontal = 16.dp)
            )

            val products = uiState.filteredProducts
            when {
                uiState.isLoading && uiState.products.isEmpty() -> Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) { CircularProgressIndicator() }

                products.isEmpty() -> Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = stringResource(R.string.products_empty),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                else -> LazyColumn(
                    // Room at the bottom so the FAB never covers the last row.
                    contentPadding = PaddingValues(bottom = 88.dp)
                ) {
                    items(products, key = { it.id }) { product ->
                        ProductRow(
                            product = product,
                            categoryName = uiState.categoryName(product.category),
                            imageVersion = uiState.imageVersions[product.id],
                            onClick = { sheetProductId = product.id }
                        )
                        HorizontalDivider()
                    }
                }
            }
        }
    }

    val openId = sheetProductId
    if (openId != null) {
        ProductEditSheet(
            viewModel = viewModel,
            productId = openId.takeIf { it != NEW_PRODUCT },
            onDismiss = { sheetProductId = null }
        )
    }
}

@Composable
private fun ProductRow(product: Product, categoryName: String?, imageVersion: Long?, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp)
    ) {
        ProductImage(imagePath = product.imagePath, contentDescription = null, cacheKey = imageVersion)
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = product.name.orEmpty(),
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = if (product.discontinued) MaterialTheme.colorScheme.onSurfaceVariant
                else MaterialTheme.colorScheme.onSurface
            )
            val subtitle = listOfNotNull(
                categoryName,
                if (product.discontinued) stringResource(R.string.product_discontinued) else null
            ).joinToString(" · ")
            if (subtitle.isNotEmpty()) {
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        product.sellprice?.let {
            Spacer(Modifier.width(4.dp))
            Text(formatEuro(it), style = MaterialTheme.typography.bodyMedium)
        }
    }
}
