package xyz.vmflow.data

import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import xyz.vmflow.models.Product
import xyz.vmflow.models.Tray
import xyz.vmflow.models.TrayUpsert

object TrayRepository {
    private val postgrest get() = SupabaseService.client.postgrest

    suspend fun fetchTrays(machineId: String): Result<List<Tray>> {
        return try {
            val trays = postgrest.from("machine_trays")
                .select(Columns.raw("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(id, name, image_path, discontinued, sellprice)")) {
                    filter { eq("machine_id", machineId) }
                    order("item_number", Order.ASCENDING)
                }
                .decodeList<Tray>()
            Result.success(trays)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun upsertTray(tray: TrayUpsert): Result<Unit> {
        return try {
            postgrest.from("machine_trays")
                .upsert(tray)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun deleteTray(trayId: String): Result<Unit> {
        return try {
            postgrest.from("machine_trays")
                .delete {
                    filter { eq("id", trayId) }
                }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateStock(trayId: String, newStock: Int): Result<Unit> {
        return try {
            postgrest.from("machine_trays")
                .update({
                    set("current_stock", newStock)
                }) {
                    filter { eq("id", trayId) }
                }
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun batchCreateTrays(
        machineId: String,
        startSlot: Int,
        count: Int,
        capacity: Int
    ): Result<Unit> {
        return try {
            val trays = (0 until count).map { i ->
                TrayUpsert(
                    machineId = machineId,
                    itemNumber = startSlot + i,
                    capacity = capacity,
                    currentStock = 0
                )
            }
            postgrest.from("machine_trays")
                .insert(trays)
            Result.success(Unit)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchProducts(): Result<List<Product>> {
        return try {
            val products = postgrest.from("products")
                .select {
                    filter { eq("discontinued", false) }
                    order("name", Order.ASCENDING)
                }
                .decodeList<Product>()
            Result.success(products)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
