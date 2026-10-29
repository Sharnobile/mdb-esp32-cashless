package xyz.vmflow.ui.products

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import xyz.vmflow.data.ProductEditLogic
import java.io.ByteArrayOutputStream
import java.io.File

/** A photo ready for upload plus a bitmap to preview it with. */
class ProductPhoto(val jpeg: ByteArray, val preview: Bitmap)

/**
 * Turns a camera / gallery [uri] into an upload-ready JPEG: decoded with an
 * `inSampleSize` (a 12 MP photo is never fully loaded), rotated by its EXIF
 * orientation (camera apps store portrait shots sideways plus a tag that
 * `BitmapFactory` ignores), scaled to [ProductEditLogic.MAX_IMAGE_DIMENSION]
 * and re-encoded. Null if the image cannot be read.
 */
suspend fun loadProductPhoto(context: Context, uri: Uri): ProductPhoto? = withContext(Dispatchers.IO) {
    runCatching {
        val resolver = context.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@runCatching null

        val options = BitmapFactory.Options().apply {
            inSampleSize = ProductEditLogic.sampleSize(bounds.outWidth, bounds.outHeight)
        }
        val decoded = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
            ?: return@runCatching null

        val orientation = resolver.openInputStream(uri)?.use {
            ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        } ?: ExifInterface.ORIENTATION_NORMAL
        val rotation = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }

        val (w, h) = ProductEditLogic.scaledDimensions(decoded.width, decoded.height)
        val matrix = Matrix().apply {
            postScale(w.toFloat() / decoded.width, h.toFloat() / decoded.height)
            if (rotation != 0f) postRotate(rotation)
        }
        val result = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)

        val out = ByteArrayOutputStream()
        result.compress(Bitmap.CompressFormat.JPEG, ProductEditLogic.JPEG_QUALITY, out)
        ProductPhoto(out.toByteArray(), result)
    }.getOrNull()
}

/**
 * Content URI the camera app writes the shot into (`TakePicture` needs one).
 * One fixed file in the cache: it is read right after capture, then unused.
 */
fun productCaptureUri(context: Context): Uri {
    val dir = File(context.cacheDir, "product_photos").apply { mkdirs() }
    val file = File(dir, "capture.jpg")
    return FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
}
