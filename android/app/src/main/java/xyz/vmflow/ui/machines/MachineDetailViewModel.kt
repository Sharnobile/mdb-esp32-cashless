package xyz.vmflow.ui.machines

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import xyz.vmflow.data.MachineRepository
import xyz.vmflow.data.TrayRepository
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.models.Product
import xyz.vmflow.models.Sale
import xyz.vmflow.models.Tray

data class MachineDetailUiState(
    val isLoading: Boolean = true,
    val isRefreshing: Boolean = false,
    val machineStats: MachineWithStats? = null,
    val sales: List<Sale> = emptyList(),
    val products: List<Product> = emptyList(),
    val error: String? = null,
    val selectedTab: Int = 0
)

class MachineDetailViewModel : ViewModel() {
    private val _uiState = MutableStateFlow(MachineDetailUiState())
    val uiState: StateFlow<MachineDetailUiState> = _uiState.asStateFlow()

    private var machineId: String = ""

    fun loadMachine(id: String) {
        machineId = id
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)

            val detailResult = MachineRepository.fetchMachineDetail(id)
            detailResult.fold(
                onSuccess = { stats ->
                    _uiState.value = _uiState.value.copy(machineStats = stats)
                },
                onFailure = { e ->
                    _uiState.value = _uiState.value.copy(error = e.message)
                }
            )

            val salesResult = MachineRepository.fetchMachineSales(id)
            salesResult.onSuccess { sales ->
                _uiState.value = _uiState.value.copy(sales = sales)
            }

            val productsResult = TrayRepository.fetchProducts()
            productsResult.onSuccess { products ->
                _uiState.value = _uiState.value.copy(products = products)
            }

            _uiState.value = _uiState.value.copy(isLoading = false)
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isRefreshing = true)
            loadMachine(machineId)
            _uiState.value = _uiState.value.copy(isRefreshing = false)
        }
    }

    fun selectTab(index: Int) {
        _uiState.value = _uiState.value.copy(selectedTab = index)
    }

    fun updateTrayStock(trayId: String, delta: Int) {
        viewModelScope.launch {
            val trays = _uiState.value.machineStats?.trays ?: return@launch
            val tray = trays.find { it.id == trayId } ?: return@launch
            val newStock = (tray.currentStock + delta).coerceIn(0, tray.capacity)
            TrayRepository.updateStock(trayId, newStock).onSuccess {
                // Update local state
                val updatedTrays = trays.map {
                    if (it.id == trayId) {
                        Tray(
                            id = it.id,
                            machineId = it.machineId,
                            itemNumber = it.itemNumber,
                            productId = it.productId,
                            capacity = it.capacity,
                            currentStock = newStock,
                            minStock = it.minStock,
                            fillWhenBelow = it.fillWhenBelow,
                            products = it.products
                        )
                    } else it
                }
                _uiState.value = _uiState.value.copy(
                    machineStats = _uiState.value.machineStats?.copy(trays = updatedTrays)
                )
            }
        }
    }

    fun deleteTray(trayId: String) {
        viewModelScope.launch {
            TrayRepository.deleteTray(trayId).onSuccess {
                loadMachine(machineId)
            }
        }
    }
}
