package xyz.vmflow.data

import xyz.vmflow.models.Product
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Pure helpers behind the product create/edit sheet (`ui/products`). Ported
 * from iOS `ProductEditSheet.swift` so both apps parse prices, name barcode
 * formats and size product photos the same way.
 */
object ProductEditLogic {

    /**
     * Longest side of an uploaded product photo. A camera shot is 12+ MP and
     * several MB, over the 2 MiB limit of the `product-images` bucket; a
     * product thumbnail never needs more. Same value as iOS.
     */
    const val MAX_IMAGE_DIMENSION = 1200
    const val JPEG_QUALITY = 80

    /** "1,50" and "1.50" both mean 1.5; blank means no price. Null for anything unparsable. */
    fun parsePrice(text: String): Double? =
        text.trim().replace(',', '.').takeIf { it.isNotEmpty() }?.toDoubleOrNull()

    /** True when [text] is blank or a valid price — the save button's gate. */
    fun isPriceValid(text: String): Boolean = text.isBlank() || parsePrice(text) != null

    /** Price as the edit field shows it ("1.50"), empty for no price. */
    fun formatPrice(price: Double?): String = price?.let { String.format(java.util.Locale.US, "%.2f", it) } ?: ""

    /** Same length heuristic as iOS `detectBarcodeFormat`. */
    fun detectBarcodeFormat(code: String): String = when (code.length) {
        8 -> "EAN-8"
        12 -> "UPC-A"
        13 -> "EAN-13"
        else -> if (code.all { it.isDigit() }) "EAN-13" else "CODE-128"
    }

    /** Target size for [width] × [height] with the longest side capped at [maxDimension]; never upscales. */
    fun scaledDimensions(width: Int, height: Int, maxDimension: Int = MAX_IMAGE_DIMENSION): Pair<Int, Int> {
        val longest = max(width, height)
        if (longest <= maxDimension || longest <= 0) return width to height
        val scale = maxDimension.toDouble() / longest
        return max(1, (width * scale).roundToInt()) to max(1, (height * scale).roundToInt())
    }

    /**
     * Largest power-of-two `inSampleSize` that keeps the decoded bitmap at or
     * above [maxDimension] on its longest side, so a 12 MP photo is never
     * fully decoded into memory just to be shrunk afterwards.
     */
    fun sampleSize(width: Int, height: Int, maxDimension: Int = MAX_IMAGE_DIMENSION): Int {
        var sample = 1
        val longest = max(width, height)
        while (longest / (sample * 2) >= maxDimension) sample *= 2
        return sample
    }

    /**
     * Open Food Facts quantities are free text ("500 ml", "1,5 l", "33cl").
     * Normalizes the spelled-out units only; passes anything else through.
     */
    fun normalizeQuantityUnit(raw: String): String {
        var q = raw
        val replacements = listOf(
            "milliliters" to "ml", "millilitres" to "ml", "milliliter" to "ml", "millilitre" to "ml",
            "centiliters" to "cl", "centilitres" to "cl", "centiliter" to "cl", "centilitre" to "cl",
            "liters" to "L", "litres" to "L", "liter" to "L", "litre" to "L",
        )
        for ((pattern, unit) in replacements) q = q.replace(pattern, unit, ignoreCase = true)
        return q
    }

    /** Suggested product name from an Open Food Facts hit ("Coca-Cola 330ml"), or null without a usable name. */
    fun suggestedName(productName: String?, quantity: String?): String? {
        val name = productName?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val qty = quantity?.trim()?.takeIf { it.isNotEmpty() } ?: return name
        return "$name ${normalizeQuantityUnit(qty)}"
    }

    /** Case-insensitive name search; discontinued products only when [includeDiscontinued]. */
    fun filterProducts(products: List<Product>, query: String, includeDiscontinued: Boolean): List<Product> {
        val q = query.trim()
        return products.filter { p ->
            (includeDiscontinued || !p.discontinued) &&
                (q.isEmpty() || (p.name ?: "").contains(q, ignoreCase = true))
        }
    }
}
