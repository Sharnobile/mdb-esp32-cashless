package xyz.vmflow.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.vmflow.models.Product

class ProductEditLogicTest {

    @Test
    fun `price accepts comma and dot and blank`() {
        assertEquals(1.5, ProductEditLogic.parsePrice("1,50")!!, 0.0)
        assertEquals(1.5, ProductEditLogic.parsePrice(" 1.50 ")!!, 0.0)
        assertNull(ProductEditLogic.parsePrice(""))
        assertNull(ProductEditLogic.parsePrice("abc"))
        assertTrue(ProductEditLogic.isPriceValid(""))
        assertFalse(ProductEditLogic.isPriceValid("1,5x"))
        assertEquals("2.00", ProductEditLogic.formatPrice(2.0))
        assertEquals("", ProductEditLogic.formatPrice(null))
    }

    @Test
    fun `barcode format follows the iOS length heuristic`() {
        assertEquals("EAN-8", ProductEditLogic.detectBarcodeFormat("12345678"))
        assertEquals("UPC-A", ProductEditLogic.detectBarcodeFormat("123456789012"))
        assertEquals("EAN-13", ProductEditLogic.detectBarcodeFormat("4000417025005"))
        assertEquals("EAN-13", ProductEditLogic.detectBarcodeFormat("12345"))
        assertEquals("CODE-128", ProductEditLogic.detectBarcodeFormat("AB-12"))
    }

    @Test
    fun `a camera photo is scaled to 1200 px on its longest side`() {
        assertEquals(1200 to 900, ProductEditLogic.scaledDimensions(4032, 3024))
        assertEquals(900 to 1200, ProductEditLogic.scaledDimensions(3024, 4032))
        assertEquals(800 to 600, ProductEditLogic.scaledDimensions(800, 600))
    }

    @Test
    fun `sample size never decodes below the target size`() {
        assertEquals(2, ProductEditLogic.sampleSize(4032, 3024))
        assertEquals(1, ProductEditLogic.sampleSize(2000, 1500))
        assertEquals(4, ProductEditLogic.sampleSize(8000, 6000))
        assertEquals(1, ProductEditLogic.sampleSize(800, 600))
    }

    @Test
    fun `open food facts name gets a normalized quantity`() {
        assertEquals("Coca-Cola 330 ml", ProductEditLogic.suggestedName("Coca-Cola", "330 Milliliters"))
        assertEquals("Wasser 1,5 L", ProductEditLogic.suggestedName(" Wasser ", "1,5 Liter"))
        assertEquals("Mars", ProductEditLogic.suggestedName("Mars", " "))
        assertNull(ProductEditLogic.suggestedName("  ", "500 g"))
    }

    @Test
    fun `filter searches names and hides discontinued products by default`() {
        val products = listOf(
            Product(id = "1", name = "Mars"),
            Product(id = "2", name = "Snickers", discontinued = true),
            Product(id = "3", name = "Marsmallow"),
        )
        assertEquals(listOf("1", "3"), ProductEditLogic.filterProducts(products, "mars", false).map { it.id })
        assertEquals(listOf("1", "3"), ProductEditLogic.filterProducts(products, "", false).map { it.id })
        assertEquals(listOf("1", "2", "3"), ProductEditLogic.filterProducts(products, "", true).map { it.id })
    }
}
