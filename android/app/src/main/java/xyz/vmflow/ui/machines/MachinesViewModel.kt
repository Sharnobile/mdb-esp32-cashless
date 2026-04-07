package xyz.vmflow.ui.machines

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import xyz.vmflow.data.MachineRepository
import xyz.vmflow.models.MachineWithStats

data class MachinesUiState(
    val isLoading: Boolean = true,
    val isRefreshing: Boolean = false,
    val machines: List<MachineWithStats> = emptyList(),
    val searchQuery: String = "",
    val error: String? = null
) {
    val filteredMachines: List<MachineWithStats>
        get() = if (searchQuery.isBlank()) machines
        else machines.filter {
            it.machine.displayName.contains(searchQuery, ignoreCase = true)
        }
}

class MachinesViewModel : ViewModel() {
    private val _uiState = MutableStateFlow(MachinesUiState())
    val uiState: StateFlow<MachinesUiState> = _uiState.asStateFlow()

    init {
        loadMachines()
    }

    fun loadMachines() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            val result = MachineRepository.fetchMachinesWithStats()
            result.fold(
                onSuccess = { machines ->
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        machines = machines
                    )
                },
                onFailure = { e ->
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = e.message
                    )
                }
            )
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isRefreshing = true)
            val result = MachineRepository.fetchMachinesWithStats()
            result.onSuccess { machines ->
                _uiState.value = _uiState.value.copy(machines = machines)
            }
            _uiState.value = _uiState.value.copy(isRefreshing = false)
        }
    }

    fun updateSearch(query: String) {
        _uiState.value = _uiState.value.copy(searchQuery = query)
    }
}
