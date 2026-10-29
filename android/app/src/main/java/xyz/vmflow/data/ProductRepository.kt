package xyz.vmflow.data

import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.storage.storage
import io.ktor.http.ContentType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import xyz.vmflow.models.Product
import xyz.vmflow.models.ProductCategory
import java.net.HttpURLConnection
import java.net.URL

/** `product_barcodes` row as the product sheet lists it. */
@Serializable
data class ProductBarcode(
    val id: String,
    @SerialName("product_id") val productId: String,
    val barcode: String,
    val format: String? = null
)

/** Insert payload for [ProductRepository.createProduct] — no defaults, so null price / category are sent explicitly. */
@Serializable
private data class ProductInsert(
    val name: String,
    val sellprice: Double?,
    val category: String?,
    val discontinued: Boolean,
    val company: String
)

@Serializable
private data class ProductBarcodeInsert(
    @SerialName("product_id") val productId: String,
    val barcode: String,
    val format: String,
    @SerialName("company_id") val companyId: String
)

@Serializable
private data class InsertedProductIdRow(val id: String)

/**
 * Product catalogue CRUD for the Products tab and the "new product" flow of
 * the warehouse intake. Mirrors iOS `ProductsViewModel.swift` (same tables,
 * columns, storage path `{product_id}.jpg` in `product-images`).
 */
object ProductRepository {
    private const val IMAGE_BUCKET = "product-images"

    private val postgrest get() = SupabaseService.client.postgrest
    private val storage get() = SupabaseService.client.storage

    /** Every product, discontinued ones included — the list filters client-side. */
    suspend fun fetchProducts(): Result<List<Product>> = runCatching {
        postgrest.from("products")
            .select(Columns.raw("id, name, image_path, discontinued, sellprice, category")) {
                order("name", Order.ASCENDING)
            }
            .decodeList<Product>()
    }

    suspend fun fetchCategories(): Result<List<ProductCategory>> = runCatching {
        postgrest.from("product_category")
            .select(Columns.raw("id, name, company")) {
                order("name", Order.ASCENDING)
            }
            .decodeList<ProductCategory>()
    }

    /** Creates a product in [companyId] and returns its id. */
    suspend fun createProduct(
        companyId: String,
        name: String,
        sellprice: Double?,
        categoryId: String?,
        discontinued: Boolean
    ): Result<String> = runCatching {
        postgrest.from("products")
            .insert(ProductInsert(name, sellprice, categoryId, discontinued, companyId)) {
                select(Columns.raw("id"))
            }
            .decodeList<InsertedProductIdRow>()
            .firstOrNull()?.id
            ?: error("Product insert returned no row")
    }

    /** Clearing the price or category writes an explicit null (same as iOS `ProductUpdate`). */
    suspend fun updateProduct(
        id: String,
        name: String,
        sellprice: Double?,
        categoryId: String?,
        discontinued: Boolean
    ): Result<Unit> = runCatching {
        postgrest.from("products").update({
            set("name", name)
            set("discontinued", discontinued)
            if (sellprice == null) setToNull("sellprice") else set("sellprice", sellprice)
            if (categoryId == null) setToNull("category") else set("category", categoryId)
        }) {
            filter { eq("id", id) }
        }
        Unit
    }

    /** Deletes the product and, best effort, its image. */
    suspend fun deleteProduct(product: Product): Result<Unit> = runCatching {
        product.imagePath?.let { path -> runCatching { storage.from(IMAGE_BUCKET).delete(listOf(path)) } }
        postgrest.from("products").delete { filter { eq("id", product.id) } }
        Unit
    }

    /** Uploads (upsert) a JPEG as `{id}.jpg` and points `image_path` at it. Returns the path. */
    suspend fun uploadImage(productId: String, jpeg: ByteArray): Result<String> = runCatching {
        val path = "$productId.jpg"
        storage.from(IMAGE_BUCKET).upload(path, jpeg) {
            upsert = true
            contentType = ContentType.Image.JPEG
        }
        postgrest.from("products").update({ set("image_path", path) }) {
            filter { eq("id", productId) }
        }
        path
    }

    suspend fun deleteImage(productId: String, imagePath: String): Result<Unit> = runCatching {
        storage.from(IMAGE_BUCKET).delete(listOf(imagePath))
        postgrest.from("products").update({ setToNull("image_path") }) {
            filter { eq("id", productId) }
        }
        Unit
    }

    suspend fun fetchBarcodes(productId: String): Result<List<ProductBarcode>> = runCatching {
        postgrest.from("product_barcodes")
            .select(Columns.raw("id, product_id, barcode, format")) {
                filter { eq("product_id", productId) }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<ProductBarcode>()
    }

    suspend fun addBarcode(companyId: String, productId: String, barcode: String, format: String): Result<Unit> = runCatching {
        postgrest.from("product_barcodes").insert(ProductBarcodeInsert(productId, barcode, format, companyId))
        Unit
    }

    suspend fun deleteBarcode(id: String): Result<Unit> = runCatching {
        postgrest.from("product_barcodes").delete { filter { eq("id", id) } }
        Unit
    }

    /**
     * Product name suggestion for a scanned barcode from Open Food Facts
     * ("Coca-Cola 330ml"), or null when unknown / offline. Same lookup as iOS
     * `lookupBarcodeProduct`.
     */
    suspend fun lookupOpenFoodFactsName(code: String): String? = withContext(Dispatchers.IO) {
        if (code.isBlank() || !code.all { it.isLetterOrDigit() }) return@withContext null
        runCatching {
            val url = URL("https://world.openfoodfacts.org/api/v2/product/$code.json?fields=product_name,quantity")
            val connection = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 8000
                readTimeout = 8000
            }
            try {
                if (connection.responseCode != 200) return@runCatching null
                val body = connection.inputStream.bufferedReader().use { it.readText() }
                val root = Json.parseToJsonElement(body).jsonObject
                if (root["status"]?.jsonPrimitive?.intOrNull != 1) return@runCatching null
                val product = root["product"] as? JsonObject ?: return@runCatching null
                ProductEditLogic.suggestedName(
                    product["product_name"]?.jsonPrimitive?.contentOrNull,
                    product["quantity"]?.jsonPrimitive?.contentOrNull
                )
            } finally {
                connection.disconnect()
            }
        }.getOrNull()
    }
}
