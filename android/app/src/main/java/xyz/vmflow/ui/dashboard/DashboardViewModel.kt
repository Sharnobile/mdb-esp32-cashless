package xyz.vmflow.ui.dashboard

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import xyz.vmflow.data.AuthRepository
import xyz.vmflow.data.MachineRepository
import xyz.vmflow.models.MachineWithStats
import xyz.vmflow.models.Organization
import xyz.vmflow.models.Sale

data class DashboardUiState(
    val isLoading: Boolean = true,
    val isRefreshing: Boolean = false,
    val organization: Organization? = null,
    val role: String? = null,
    val machines: List<MachineWithStats> = emptyList(),
    val recentSales: List<Sale> = emptyList(),
    val error: String? = null
) {
    val todayRevenue: Double get() = machines.sumOf { it.todayRevenue }
    val todaySalesCount: Int get() = machines.sumOf { it.todaySalesCount }
    val machinesOnline: Int get() = machines.count { it.machine.isOnline }
    val totalMachines: Int get() = machines.size
    val stockAlerts: Int get() = machines.count {
        it.stockHealth != MachineWithStats.StockHealth.OK
    }
}

class DashboardViewModel : ViewModel() {
    private val _uiState = MutableStateFlow(DashboardUiState())
    val uiState: StateFlow<DashboardUiState> = _uiState.asStateFlow()

    init {
        loadData()
    }

    fun loadData() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)

            // Fetch organization
            val orgResult = AuthRepository.fetchOrganization()
            orgResult.onSuccess { response ->
                _uiState.value = _uiState.value.copy(
                    organization = response.organization,
                    role = response.role
                )
            }

            // Fetch machines with stats
            val machinesResult = MachineRepository.fetchMachinesWithStats()
            machinesResult.fold(
                onSuccess = { machines ->
                    _uiState.value = _uiState.value.copy(machines = machines)
                },
                onFailure = { e ->
                    _uiState.value = _uiState.value.copy(error = e.message)
                }
            )

            // Fetch recent sales
            val salesResult = MachineRepository.fetchRecentSales(10)
            salesResult.onSuccess { sales ->
                _uiState.value = _uiState.value.copy(recentSales = sales)
            }

            _uiState.value = _uiState.value.copy(isLoading = false)
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isRefreshing = true)
            loadData()
            _uiState.value = _uiState.value.copy(isRefreshing = false)
        }
    }

    suspend fun signOut() {
        AuthRepository.signOut()
    }
}
