package xyz.vmflow.data

import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.datetime.Clock
import kotlinx.datetime.LocalDate
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.models.Paxcounter
import xyz.vmflow.models.Sale
import xyz.vmflow.models.Tray
import xyz.vmflow.models.VendingMachineWithEmbedded

object MachineRepository {
    private val postgrest get() = SupabaseService.client.postgrest

    suspend fun fetchMachines(): Result<List<VendingMachineWithEmbedded>> {
        return try {
            val machines = postgrest.from("vendingMachine")
                .select(Columns.raw("id, name, location_lat, location_lon, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)"))
                .decodeList<VendingMachineWithEmbedded>()
            Result.success(machines)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchMachinesWithStats(): Result<List<MachineWithStats>> {
        return try {
            val machines = fetchMachines().getOrThrow()
            val now = Clock.System.now()
            val tz = TimeZone.currentSystemDefault()
            val todayDate = now.toLocalDateTime(tz).date
            val yesterdayDate = LocalDate(todayDate.year, todayDate.month, todayDate.dayOfMonth)
                .let {
                    val epochDays = it.toEpochDays() - 1
                    LocalDate.fromEpochDays(epochDays)
                }
            val todayStart = "${todayDate}T00:00:00"
            val yesterdayStart = "${yesterdayDate}T00:00:00"
            val yesterdayEnd = "${todayDate}T00:00:00"

            val machinesWithStats = machines.map { machine ->
                try {
                    val todaySales = postgrest.from("sales")
                        .select {
                            filter {
                                eq("machine_id", machine.id)
                                gte("created_at", todayStart)
                            }
                        }
                        .decodeList<Sale>()

                    val yesterdaySales = postgrest.from("sales")
                        .select {
                            filter {
                                eq("machine_id", machine.id)
                                gte("created_at", yesterdayStart)
                                lt("created_at", yesterdayEnd)
                            }
                        }
                        .decodeList<Sale>()

                    val lastSale = postgrest.from("sales")
                        .select {
                            filter {
                                eq("machine_id", machine.id)
                            }
                            order("created_at", Order.DESCENDING)
                            limit(1)
                        }
                        .decodeList<Sale>()
                        .firstOrNull()

                    val trays = postgrest.from("machine_trays")
                        .select(Columns.raw("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(id, name, image_path, discontinued, sellprice)")) {
                            filter {
                                eq("machine_id", machine.id)
                            }
                            order("item_number", Order.ASCENDING)
                        }
                        .decodeList<Tray>()

                    val paxCount = machine.embeddeds?.id?.let { embeddedId ->
                        try {
                            postgrest.from("paxcounter")
                                .select {
                                    filter {
                                        eq("embedded_id", embeddedId)
                                        gte("created_at", todayStart)
                                    }
                                }
                                .decodeList<Paxcounter>()
                                .sumOf { it.count }
                        } catch (_: Exception) { 0 }
                    } ?: 0

                    MachineWithStats(
                        machine = machine,
                        todayRevenue = todaySales.sumOf { it.itemPrice },
                        todaySalesCount = todaySales.size,
                        yesterdayRevenue = yesterdaySales.sumOf { it.itemPrice },
                        lastSaleAt = lastSale?.createdAt,
                        paxCount = paxCount,
                        trays = trays
                    )
                } catch (_: Exception) {
                    MachineWithStats(machine = machine)
                }
            }

            // Sort: critical > low > ok, then by lowTrayCount desc
            val sorted = machinesWithStats.sortedWith(
                compareBy<MachineWithStats> { it.stockHealth.ordinal }
                    .thenByDescending { it.lowTrayCount }
            )

            Result.success(sorted)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchMachineDetail(machineId: String): Result<MachineWithStats> {
        return try {
            val machine = postgrest.from("vendingMachine")
                .select(Columns.raw("id, name, location_lat, location_lon, country_code, embeddeds(id, status, status_at, subdomain, mac_address, firmware_version)")) {
                    filter { eq("id", machineId) }
                    limit(1)
                }
                .decodeSingle<VendingMachineWithEmbedded>()

            val now = Clock.System.now()
            val tz = TimeZone.currentSystemDefault()
            val todayDate = now.toLocalDateTime(tz).date
            val yesterdayDate = LocalDate.fromEpochDays(todayDate.toEpochDays() - 1)
            val todayStart = "${todayDate}T00:00:00"
            val yesterdayStart = "${yesterdayDate}T00:00:00"
            val yesterdayEnd = "${todayDate}T00:00:00"

            val todaySales = postgrest.from("sales")
                .select {
                    filter {
                        eq("machine_id", machineId)
                        gte("created_at", todayStart)
                    }
                }
                .decodeList<Sale>()

            val yesterdaySales = postgrest.from("sales")
                .select {
                    filter {
                        eq("machine_id", machineId)
                        gte("created_at", yesterdayStart)
                        lt("created_at", yesterdayEnd)
                    }
                }
                .decodeList<Sale>()

            val lastSale = postgrest.from("sales")
                .select {
                    filter { eq("machine_id", machineId) }
                    order("created_at", Order.DESCENDING)
                    limit(1)
                }
                .decodeList<Sale>()
                .firstOrNull()

            val trays = postgrest.from("machine_trays")
                .select(Columns.raw("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(id, name, image_path, discontinued, sellprice)")) {
                    filter { eq("machine_id", machineId) }
                    order("item_number", Order.ASCENDING)
                }
                .decodeList<Tray>()

            val paxCount = machine.embeddeds?.id?.let { embeddedId ->
                try {
                    postgrest.from("paxcounter")
                        .select {
                            filter {
                                eq("embedded_id", embeddedId)
                                gte("created_at", todayStart)
                            }
                        }
                        .decodeList<Paxcounter>()
                        .sumOf { it.count }
                } catch (_: Exception) { 0 }
            } ?: 0

            Result.success(
                MachineWithStats(
                    machine = machine,
                    todayRevenue = todaySales.sumOf { it.itemPrice },
                    todaySalesCount = todaySales.size,
                    yesterdayRevenue = yesterdaySales.sumOf { it.itemPrice },
                    lastSaleAt = lastSale?.createdAt,
                    paxCount = paxCount,
                    trays = trays
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchRecentSales(limit: Int = 20): Result<List<Sale>> {
        return try {
            val sales = postgrest.from("sales")
                .select {
                    order("created_at", Order.DESCENDING)
                    limit(limit.toLong())
                }
                .decodeList<Sale>()
            Result.success(sales)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchMachineSales(machineId: String, limit: Int = 50): Result<List<Sale>> {
        return try {
            val sales = postgrest.from("sales")
                .select {
                    filter { eq("machine_id", machineId) }
                    order("created_at", Order.DESCENDING)
                    limit(limit.toLong())
                }
                .decodeList<Sale>()
            Result.success(sales)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}
