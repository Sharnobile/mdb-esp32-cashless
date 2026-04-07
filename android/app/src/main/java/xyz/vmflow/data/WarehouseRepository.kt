package xyz.vmflow.data

import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import xyz.vmflow.models.Warehouse
import xyz.vmflow.models.WarehouseStockBatch

object WarehouseRepository {
    private val postgrest get() = SupabaseService.client.postgrest

    suspend fun fetchWarehouses(): Result<List<Warehouse>> {
        return try {
            val warehouses = postgrest.from("warehouses")
                .select()
                .decodeList<Warehouse>()
            Result.success(warehouses)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchWarehouseStock(warehouseId: String): Result<List<WarehouseStockBatch>> {
        return try {
            val batches = postgrest.from("warehouse_stock_batches")
                .select(Columns.raw("id, warehouse_id, product_id, quantity, batch_number, expiration_date, products(id, name, image_path, discontinued, sellprice)")) {
                    filter {
                        eq("warehouse_id", warehouseId)
                        gt("quantity", 0)
                    }
                    order("expiration_date", Order.ASCENDING)
                }
                .decodeList<WarehouseStockBatch>()
            Result.success(batches)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchAllWarehouseStock(): Result<List<WarehouseStockBatch>> {
        return try {
            val batches = postgrest.from("warehouse_stock_batches")
                .select(Columns.raw("id, warehouse_id, product_id, quantity, batch_number, expiration_date, products(id, name, image_path, discontinued, sellprice)")) {
                    filter {
                        gt("quantity", 0)
                    }
                }
                .decodeList<WarehouseStockBatch>()
            Result.success(batches)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
