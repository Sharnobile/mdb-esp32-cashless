package xyz.vmflow.ui.products

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import xyz.vmflow.data.AuthRepository
import xyz.vmflow.data.ProductBarcode
import xyz.vmflow.data.ProductEditLogic
import xyz.vmflow.data.ProductRepository
import xyz.vmflow.models.Product
import xyz.vmflow.models.ProductCategory

data class ProductsUiState(
    val isLoading: Boolean = true,
    val products: List<Product> = emptyList(),
    val categories: List<ProductCategory> = emptyList(),
    val companyId: String? = null,
    val searchText: String = "",
    val showDiscontinued: Boolean = false,
    /** Bumped per product when its image was replaced, see `ProductImage.cacheKey`. */
    val imageVersions: Map<String, Long> = emptyMap(),
    val isSaving: Boolean = false,
    val isUploadingImage: Boolean = false,
    val error: String? = null
) {
    val filteredProducts: List<Product>
        get() = ProductEditLogic.filterProducts(products, searchText, showDiscontinued)

    fun categoryName(id: String?): String? = id?.let { cid -> categories.firstOrNull { it.id == cid }?.name }
}

/**
 * Products tab + product sheet. Mirrors iOS `ProductsViewModel.swift`; the
 * sheet's buffered state for a new product (photo, barcodes) is flushed by
 * [saveProduct] right after the insert, like on iOS.
 */
class ProductsViewModel : ViewModel() {
    private val _uiState = MutableStateFlow(ProductsUiState())
    val uiState: StateFlow<ProductsUiState> = _uiState.asStateFlow()

    init {
        loadAll()
    }

    fun loadAll() {
        viewModelScope.launch {
            _uiState.update { it.copy(isLoading = true) }
            coroutineScope {
                launch { loadProducts() }
                launch {
                    ProductRepository.fetchCategories().onSuccess { c -> _uiState.update { it.copy(categories = c) } }
                }
                launch {
                    AuthRepository.fetchOrganization().onSuccess { r ->
                        _uiState.update { it.copy(companyId = r.organization?.id) }
                    }
                }
            }
            _uiState.update { it.copy(isLoading = false) }
        }
    }

    private suspend fun loadProducts() {
        ProductRepository.fetchProducts().fold(
            onSuccess = { p -> _uiState.update { it.copy(products = p) } },
            onFailure = { e -> _uiState.update { it.copy(error = e.message) } }
        )
    }

    fun updateSearch(text: String) = _uiState.update { it.copy(searchText = text) }
    fun toggleShowDiscontinued() = _uiState.update { it.copy(showDiscontinued = !it.showDiscontinued) }
    fun clearError() = _uiState.update { it.copy(error = null) }

    /**
     * Creates ([existing] == null) or updates a product. For a new product the
     * photo and barcodes collected in the sheet are written right after the
     * insert. [onDone] gets the product id on success, null on failure.
     */
    fun saveProduct(
        existing: Product?,
        name: String,
        sellprice: Double?,
        categoryId: String?,
        discontinued: Boolean,
        pendingPhoto: ByteArray?,
        pendingBarcodes: List<String>,
        onDone: (String?) -> Unit
    ) {
        viewModelScope.launch {
            _uiState.update { it.copy(isSaving = true, error = null) }
            val productId: String? = if (existing != null) {
                ProductRepository.updateProduct(existing.id, name, sellprice, categoryId, discontinued)
                    .fold(onSuccess = { existing.id }, onFailure = { e -> fail(e); null })
            } else {
                val companyId = _uiState.value.companyId ?: resolveCompanyId()
                if (companyId == null) {
                    _uiState.update { it.copy(error = "Could not determine company") }
                    null
                } else {
                    ProductRepository.createProduct(companyId, name, sellprice, categoryId, discontinued)
                        .fold(onSuccess = { it }, onFailure = { e -> fail(e); null })
                }
            }

            if (productId != null && existing == null) {
                val companyId = _uiState.value.companyId
                if (companyId != null) {
                    for (code in pendingBarcodes) {
                        ProductRepository.addBarcode(companyId, productId, code, ProductEditLogic.detectBarcodeFormat(code))
                            .onFailure { e -> fail(e) }
                    }
                }
                if (pendingPhoto != null) {
                    ProductRepository.uploadImage(productId, pendingPhoto).onFailure { e -> fail(e) }
                }
            }

            loadProducts()
            if (productId != null) bumpImageVersion(productId)
            _uiState.update { it.copy(isSaving = false) }
            onDone(productId)
        }
    }

    /** Existing product: the photo goes up immediately (same as iOS). */
    fun uploadImage(productId: String, jpeg: ByteArray) {
        viewModelScope.launch {
            _uiState.update { it.copy(isUploadingImage = true) }
            ProductRepository.uploadImage(productId, jpeg).fold(
                onSuccess = { path ->
                    _uiState.update { s ->
                        s.copy(products = s.products.map { if (it.id == productId) it.copy(imagePath = path) else it })
                    }
                    bumpImageVersion(productId)
                },
                onFailure = { e -> fail(e) }
            )
            _uiState.update { it.copy(isUploadingImage = false) }
        }
    }

    fun deleteImage(product: Product) {
        val path = product.imagePath ?: return
        viewModelScope.launch {
            _uiState.update { it.copy(isUploadingImage = true) }
            ProductRepository.deleteImage(product.id, path).fold(
                onSuccess = {
                    _uiState.update { s ->
                        s.copy(products = s.products.map { if (it.id == product.id) it.copy(imagePath = null) else it })
                    }
                },
                onFailure = { e -> fail(e) }
            )
            _uiState.update { it.copy(isUploadingImage = false) }
        }
    }

    fun deleteProduct(product: Product, onDone: () -> Unit) {
        viewModelScope.launch {
            ProductRepository.deleteProduct(product).fold(
                onSuccess = {
                    _uiState.update { s -> s.copy(products = s.products.filterNot { it.id == product.id }) }
                    onDone()
                },
                onFailure = { e -> fail(e) }
            )
        }
    }

    fun loadBarcodes(productId: String, onResult: (List<ProductBarcode>) -> Unit) {
        viewModelScope.launch {
            ProductRepository.fetchBarcodes(productId).fold(onSuccess = onResult, onFailure = { e -> fail(e) })
        }
    }

    /** Existing product: saved right away, [onResult] gets the refreshed list. */
    fun addBarcode(productId: String, code: String, onResult: (List<ProductBarcode>) -> Unit) {
        viewModelScope.launch {
            val companyId = _uiState.value.companyId ?: resolveCompanyId() ?: return@launch
            ProductRepository.addBarcode(companyId, productId, code, ProductEditLogic.detectBarcodeFormat(code)).fold(
                onSuccess = { ProductRepository.fetchBarcodes(productId).onSuccess(onResult) },
                onFailure = { e -> fail(e) }
            )
        }
    }

    fun deleteBarcode(barcode: ProductBarcode, onDone: () -> Unit) {
        viewModelScope.launch {
            ProductRepository.deleteBarcode(barcode.id).fold(onSuccess = { onDone() }, onFailure = { e -> fail(e) })
        }
    }

    /** Name suggestion for a scanned barcode (Open Food Facts); null when unknown. */
    fun lookupName(code: String, onResult: (String) -> Unit) {
        viewModelScope.launch {
            ProductRepository.lookupOpenFoodFactsName(code)?.let(onResult)
        }
    }

    fun reportError(message: String) = _uiState.update { it.copy(error = message) }

    private suspend fun resolveCompanyId(): String? {
        val id = AuthRepository.fetchOrganization().getOrNull()?.organization?.id
        if (id != null) _uiState.update { it.copy(companyId = id) }
        return id
    }

    private fun bumpImageVersion(productId: String) = _uiState.update {
        it.copy(imageVersions = it.imageVersions + (productId to System.currentTimeMillis()))
    }

    private fun fail(e: Throwable) {
        Log.w(TAG, "Product operation failed", e)
        _uiState.update { it.copy(error = e.message ?: e.toString()) }
    }

    private companion object {
        const val TAG = "ProductsViewModel"
    }
}
