import { useSupabaseClient } from '#imports'
import { useOrganization } from './useOrganization'

// ── Types ────────────────────────────────────────────────────────────────────

export type WizardStep = 'packing' | 'refill' | 'summary'

export interface RefillMachine {
  id: string
  name: string
  stock_health: 'ok' | 'low' | 'critical'
  stock_percent: number
  empty_trays: number
  low_trays: number
  total_trays: number
  tray_summary: RefillItem[]
}

export interface RefillItem {
  product_id: string | null
  product_name: string
  deficit: number
  image_path: string | null
}

export interface TrayForRefill {
  id: string
  item_number: number
  product_id: string | null
  product_name: string | null
  image_path: string | null
  capacity: number
  current_stock: number
  min_stock: number
  fill_when_below: number
  /** Amount the refiller will add (editable, defaults to packed amount or deficit) */
  fill_amount: number
}

export interface TourLogEntry {
  machine_id: string
  machine_name: string
  trays_refilled: number
  total_added: number
  skipped: boolean
}

// ── Persistence ──────────────────────────────────────────────────────────────

const STORAGE_KEY = 'refill-tour-state'

interface PersistedTourState {
  currentStep: WizardStep
  machines: RefillMachine[]
  currentMachineIndex: number
  selectedWarehouseId: string | null
  /** packedQuantities as [machineId, [productId, qty][]][] */
  packedQuantities: [string, [string, number][]][]
  /** completedMachineIds as string[] */
  completedMachineIds: string[]
  tourLog: TourLogEntry[]
  savedAt: number
}

/** Max age of persisted state (24 hours) */
const MAX_AGE_MS = 24 * 60 * 60 * 1000

/** Check if there is a saved tour to resume (standalone, no composable needed) */
export function hasSavedTour(): boolean {
  if (import.meta.server) return false
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return false
    const state = JSON.parse(raw) as PersistedTourState
    if (Date.now() - state.savedAt > MAX_AGE_MS) {
      localStorage.removeItem(STORAGE_KEY)
      return false
    }
    return state.currentStep === 'refill' || state.currentStep === 'summary'
  } catch {
    return false
  }
}

/** Clear saved tour state (standalone, no composable needed) */
export function clearSavedTourState(): void {
  if (import.meta.server) return
  try { localStorage.removeItem(STORAGE_KEY) } catch { /* ignore */ }
}

// ── Composable ───────────────────────────────────────────────────────────────

export function useRefillWizard() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()

  // Wizard state
  const currentStep = ref<WizardStep>('packing')
  const machines = ref<RefillMachine[]>([])
  const currentMachineIndex = ref(0)
  const selectedWarehouseId = ref<string | null>(null)
  const warehouseStock = ref(new Map<string, number>())
  const loading = ref(false)
  const tourStarting = ref(false)
  const confirmingRefill = ref(false)

  // Packing state: machineId → Set<productKey>
  const packedItems = ref(new Map<string, Set<string>>())
  // Packed quantities: machineId → Map<productId, qty>
  const packedQuantities = ref(new Map<string, Map<string, number>>())
  // Committed quantities during packing: machineId → Map<productKey, qty>
  // Tracks how much warehouse stock is committed per machine per product
  const committedQuantities = ref(new Map<string, Map<string, number>>())

  // Refill state: trays for the current machine
  const currentTrays = ref<TrayForRefill[]>([])
  const currentTraysLoading = ref(false)

  // Tour log
  const tourLog = ref<TourLogEntry[]>([])

  // Track which machines have been completed or skipped during refill step
  const completedMachineIds = ref(new Set<string>())

  // ── Computed ─────────────────────────────────────────────────────────────

  const currentMachine = computed(() => machines.value[currentMachineIndex.value] ?? null)

  const machinesNeedingRefill = computed(() =>
    machines.value.filter(m => m.stock_health !== 'ok')
  )

  const totalMachinesInTour = computed(() => {
    // Count machines that have at least one packed item
    return machines.value.filter(m => {
      const set = packedItems.value.get(m.id)
      return set && set.size > 0
    }).length
  })

  const currentMachineNumber = computed(() => currentMachineIndex.value + 1)

  // ── Packing helpers ──────────────────────────────────────────────────────

  function itemKey(item: { product_id: string | null; product_name: string }): string {
    return item.product_id ?? item.product_name
  }

  function isPacked(machineId: string, item: { product_id: string | null; product_name: string }): boolean {
    return packedItems.value.get(machineId)?.has(itemKey(item)) ?? false
  }

  function togglePacked(machineId: string, item: { product_id: string | null; product_name: string }) {
    if (isOutOfWarehouseStock(item, machineId)) return
    const key = itemKey(item)
    const current = packedItems.value.get(machineId) ?? new Set<string>()
    if (current.has(key)) {
      current.delete(key)
    } else {
      current.add(key)
    }
    packedItems.value.set(machineId, current)
    packedItems.value = new Map(packedItems.value)
    recalculateCommittedQuantities()
  }

  function allPacked(machineId: string, items: RefillItem[]): boolean {
    if (!items || items.length === 0) return false
    const packable = items.filter(item => !isOutOfWarehouseStock(item, machineId))
    if (packable.length === 0) return false
    const set = packedItems.value.get(machineId)
    if (!set) return false
    return packable.every(item => set.has(itemKey(item)))
  }

  function getWarehouseAvailable(item: { product_id: string | null }): number | null {
    if (!selectedWarehouseId.value || !item.product_id) return null
    return warehouseStock.value.get(item.product_id) ?? 0
  }

  /**
   * Returns remaining warehouse stock for a product after subtracting
   * quantities committed (checked) by all machines.
   */
  function getWarehouseRemaining(productId: string): number {
    const total = warehouseStock.value.get(productId) ?? 0
    let committed = 0
    for (const [, machineMap] of committedQuantities.value) {
      committed += machineMap.get(productId) ?? 0
    }
    return Math.max(0, total - committed)
  }

  /**
   * Recalculate committed quantities across all machines.
   * Processes machines in display order (urgency-sorted), so higher-priority
   * machines get first claim on limited warehouse stock.
   */
  function recalculateCommittedQuantities() {
    const newCommitted = new Map<string, Map<string, number>>()
    // Track remaining warehouse stock per product during calculation
    const remaining = new Map<string, number>()
    for (const [pid, qty] of warehouseStock.value) {
      remaining.set(pid, qty)
    }

    for (const machine of machines.value) {
      const checked = packedItems.value.get(machine.id)
      if (!checked || checked.size === 0) continue

      const machineMap = new Map<string, number>()
      for (const item of machine.tray_summary) {
        if (!item.product_id || !checked.has(itemKey(item))) continue
        const avail = remaining.get(item.product_id) ?? 0
        const qty = Math.min(item.deficit, avail)
        if (qty > 0) {
          machineMap.set(item.product_id, qty)
          remaining.set(item.product_id, avail - qty)
        }
      }
      if (machineMap.size > 0) {
        newCommitted.set(machine.id, machineMap)
      }
    }

    committedQuantities.value = newCommitted
  }

  function effectiveDeficit(item: { product_id: string | null; deficit: number }, machineId?: string): number {
    if (!selectedWarehouseId.value || !item.product_id) return item.deficit

    // If this item is checked for a specific machine, return committed qty
    if (machineId) {
      const checked = packedItems.value.get(machineId)
      if (checked?.has(itemKey(item))) {
        return committedQuantities.value.get(machineId)?.get(item.product_id) ?? 0
      }
    }

    // For unchecked items: show min(deficit, remaining warehouse stock)
    const remaining = getWarehouseRemaining(item.product_id)
    return Math.min(item.deficit, remaining)
  }

  function isOutOfWarehouseStock(item: { product_id: string | null }, machineId?: string): boolean {
    if (!selectedWarehouseId.value || !item.product_id) return false
    // If already checked for this machine, it has committed stock — not out of stock
    if (machineId) {
      const checked = packedItems.value.get(machineId)
      if (checked?.has(itemKey(item))) return false
    }
    const remaining = getWarehouseRemaining(item.product_id)
    return remaining <= 0
  }

  function hasPartialStock(item: { product_id: string | null; deficit: number }, machineId?: string): boolean {
    if (!selectedWarehouseId.value || !item.product_id) return false
    if (machineId) {
      const checked = packedItems.value.get(machineId)
      if (checked?.has(itemKey(item))) {
        const committed = committedQuantities.value.get(machineId)?.get(item.product_id) ?? 0
        return committed > 0 && committed < item.deficit
      }
    }
    const remaining = getWarehouseRemaining(item.product_id)
    return remaining > 0 && remaining < item.deficit
  }

  function hasAnyPackedItems(): boolean {
    for (const set of packedItems.value.values()) {
      if (set.size > 0) return true
    }
    return false
  }

  // ── Init ─────────────────────────────────────────────────────────────────

  async function initTour() {
    loading.value = true
    try {
      // Fetch machines with stock data (reuse fetchMachines logic via direct query)
      const { data: machineData, error: machErr } = await supabase
        .from('vendingMachine')
        .select('id, name')

      if (machErr) throw machErr

      const machineIds = (machineData ?? []).map((m: any) => m.id)
      if (machineIds.length === 0) {
        machines.value = []
        return
      }

      // Fetch all trays
      const { data: trayData, error: trayErr } = await (supabase as any)
        .from('machine_trays')
        .select('machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path)')
        .in('machine_id', machineIds)

      if (trayErr) throw trayErr

      // Build machine stock info
      const stockMap = new Map<string, {
        total: number
        low: number
        empty: number
        totalStock: number
        totalCapacity: number
        deficits: Map<string, RefillItem>
        fillBelowPending: any[]
      }>()

      for (const tray of (trayData ?? []) as any[]) {
        if (!tray.machine_id) continue
        let entry = stockMap.get(tray.machine_id)
        if (!entry) {
          entry = { total: 0, low: 0, empty: 0, totalStock: 0, totalCapacity: 0, deficits: new Map(), fillBelowPending: [] }
          stockMap.set(tray.machine_id, entry)
        }
        entry.total++
        entry.totalStock += tray.current_stock
        entry.totalCapacity += tray.capacity

        const isLow = tray.min_stock > 0 && tray.current_stock <= tray.min_stock
        const isEmpty = tray.current_stock === 0
        const isFillBelow = !isLow && !isEmpty && tray.fill_when_below > 0 && tray.current_stock <= tray.fill_when_below

        if (isEmpty) entry.empty++
        else if (isLow) entry.low++

        if (isLow || isEmpty) {
          const deficit = tray.capacity - tray.current_stock
          const productName = tray.products?.name ?? `Slot ${tray.item_number}`
          const imagePath = tray.products?.image_path ?? null
          const key = tray.product_id ?? `slot-${tray.item_number}`
          const existing = entry.deficits.get(key)
          if (existing) {
            existing.deficit += deficit
          } else {
            entry.deficits.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath })
          }
        }

        if (isFillBelow) {
          entry.fillBelowPending.push(tray)
        }
      }

      // Add fill_when_below deficits for machines with critical trays
      for (const [, entry] of stockMap) {
        if (entry.low + entry.empty === 0) continue
        for (const tray of entry.fillBelowPending) {
          const deficit = tray.capacity - tray.current_stock
          if (deficit <= 0) continue
          const productName = tray.products?.name ?? `Slot ${tray.item_number}`
          const imagePath = tray.products?.image_path ?? null
          const key = tray.product_id ?? `slot-${tray.item_number}`
          const existing = entry.deficits.get(key)
          if (existing) {
            existing.deficit += deficit
          } else {
            entry.deficits.set(key, { product_name: productName, product_id: tray.product_id, deficit, image_path: imagePath })
          }
        }
      }

      // Build RefillMachine list (only machines needing refill)
      const result: RefillMachine[] = []
      for (const m of (machineData ?? []) as any[]) {
        const stock = stockMap.get(m.id)
        if (!stock || (stock.empty === 0 && stock.low === 0)) continue
        result.push({
          id: m.id,
          name: m.name ?? 'Unnamed',
          stock_health: stock.empty > 0 ? 'critical' : 'low',
          stock_percent: stock.totalCapacity > 0 ? Math.round((stock.totalStock / stock.totalCapacity) * 100) : 0,
          empty_trays: stock.empty,
          low_trays: stock.low + stock.empty,
          total_trays: stock.total,
          tray_summary: Array.from(stock.deficits.values()).sort((a, b) => b.deficit - a.deficit),
        })
      }

      // Sort by urgency
      const healthOrder: Record<string, number> = { critical: 0, low: 1, ok: 2 }
      result.sort((a, b) => {
        const ha = healthOrder[a.stock_health] ?? 2
        const hb = healthOrder[b.stock_health] ?? 2
        if (ha !== hb) return ha - hb
        return b.low_trays - a.low_trays
      })

      machines.value = result
    } finally {
      loading.value = false
    }
  }

  async function loadWarehouseStock() {
    if (!selectedWarehouseId.value) {
      warehouseStock.value = new Map()
      return
    }
    try {
      const { data, error } = await (supabase as any)
        .from('warehouse_stock_batches')
        .select('product_id, quantity')
        .eq('warehouse_id', selectedWarehouseId.value)
        .gt('quantity', 0)
      if (error) throw error
      const map = new Map<string, number>()
      for (const b of (data ?? []) as any[]) {
        map.set(b.product_id, (map.get(b.product_id) ?? 0) + b.quantity)
      }
      warehouseStock.value = map
      recalculateCommittedQuantities()
    } catch {
      warehouseStock.value = new Map()
      recalculateCommittedQuantities()
    }
  }

  // Compute effective stock health considering warehouse availability
  // Uses raw warehouse stock (not remaining after commits) so checked items
  // don't cause the machine card to collapse.
  function effectiveStockHealth(machine: RefillMachine): string {
    if (machine.stock_health === 'ok') return 'ok'
    if (!selectedWarehouseId.value) return machine.stock_health
    // If every product in tray_summary is out of warehouse stock, downgrade to ok
    const hasRefillable = machine.tray_summary.some(item => {
      if (!item.product_id) return true
      const total = warehouseStock.value.get(item.product_id) ?? 0
      return total > 0
    })
    return hasRefillable ? machine.stock_health : 'ok'
  }

  // ── Start Tour (warehouse deduction) ────────────────────────────────────

  async function startTour() {
    if (!selectedWarehouseId.value) return
    tourStarting.value = true

    try {
      const { data: { session } } = await supabase.auth.getSession()

      // Collect all deductions from committed quantities
      const deductions: { machine_id: string; product_id: string; quantity: number }[] = []

      for (const machine of machines.value) {
        const committed = committedQuantities.value.get(machine.id)
        if (!committed || committed.size === 0) continue

        const machinePackedQty = new Map<string, number>()

        for (const [productId, qty] of committed) {
          if (qty <= 0) continue
          deductions.push({
            machine_id: machine.id,
            product_id: productId,
            quantity: qty,
          })
          machinePackedQty.set(productId, (machinePackedQty.get(productId) ?? 0) + qty)
        }

        packedQuantities.value.set(machine.id, machinePackedQty)
      }

      // Execute all deductions
      for (const d of deductions) {
        const { error } = await (supabase as any).rpc('deduct_warehouse_stock_fifo', {
          p_warehouse_id: selectedWarehouseId.value,
          p_product_id: d.product_id,
          p_quantity: d.quantity,
          p_user_id: session?.user?.id ?? null,
          p_reference_id: d.machine_id,
          p_notes: 'Refill tour',
          p_metadata: { _user_email: session?.user?.email ?? null },
        })
        if (error) throw error
      }

      // Filter machines list to only those with packed items, preserve order
      const tourMachines = machines.value.filter(m => {
        const qty = packedQuantities.value.get(m.id)
        return qty && qty.size > 0
      })
      machines.value = tourMachines

      currentMachineIndex.value = 0
      tourLog.value = []
      currentStep.value = 'refill'

      // Load trays for first machine
      if (machines.value.length > 0) {
        await loadTraysForCurrentMachine()
      } else {
        currentStep.value = 'summary'
      }

      saveTourState()
    } finally {
      tourStarting.value = false
    }
  }

  // ── Refill step ────────────────────────────────────────────────────────

  async function loadTraysForCurrentMachine() {
    const machine = currentMachine.value
    if (!machine) return

    currentTraysLoading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('machine_trays')
        .select('id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path)')
        .eq('machine_id', machine.id)
        .order('item_number')

      if (error) throw error

      const packed = packedQuantities.value.get(machine.id) ?? new Map<string, number>()

      // Build tray list, only trays needing refill
      const trays: TrayForRefill[] = []
      // Track remaining packed quantities to distribute across trays
      const remainingPacked = new Map(packed)

      for (const t of (data ?? []) as any[]) {
        const isLow = t.min_stock > 0 && t.current_stock <= t.min_stock
        const isEmpty = t.current_stock === 0
        const hasCritical = (data as any[]).some((tr: any) => tr.min_stock > 0 && tr.current_stock <= tr.min_stock)
        const isFillBelow = hasCritical && !isLow && !isEmpty && t.fill_when_below > 0 && t.current_stock <= t.fill_when_below

        if (!isLow && !isEmpty && !isFillBelow) continue

        const deficit = t.capacity - t.current_stock
        if (deficit <= 0) continue

        // Calculate fill amount from packed quantities
        // Only show trays that have packed stock to fill
        let fillAmount = 0
        if (t.product_id && remainingPacked.has(t.product_id)) {
          const available = remainingPacked.get(t.product_id)!
          fillAmount = Math.min(deficit, available)
          remainingPacked.set(t.product_id, available - fillAmount)
        }

        // Skip trays with nothing packed (out-of-stock products)
        if (fillAmount <= 0) continue

        trays.push({
          id: t.id,
          item_number: t.item_number,
          product_id: t.product_id,
          product_name: t.products?.name ?? null,
          image_path: t.products?.image_path ?? null,
          capacity: t.capacity,
          current_stock: t.current_stock,
          min_stock: t.min_stock ?? 0,
          fill_when_below: t.fill_when_below ?? 0,
          fill_amount: fillAmount,
        })
      }

      currentTrays.value = trays
    } finally {
      currentTraysLoading.value = false
    }
  }

  function adjustFillAmount(trayId: string, delta: number) {
    const tray = currentTrays.value.find(t => t.id === trayId)
    if (!tray) return
    const maxFill = tray.capacity - tray.current_stock
    tray.fill_amount = Math.max(0, Math.min(maxFill, tray.fill_amount + delta))
  }

  function setFillAmount(trayId: string, amount: number) {
    const tray = currentTrays.value.find(t => t.id === trayId)
    if (!tray) return
    const maxFill = tray.capacity - tray.current_stock
    tray.fill_amount = Math.max(0, Math.min(maxFill, amount))
  }

  async function confirmMachineRefill() {
    const machine = currentMachine.value
    if (!machine) return

    confirmingRefill.value = true
    try {
      const traysToRefill = currentTrays.value.filter(t => t.fill_amount > 0)
      let totalAdded = 0

      // Use refillTrayByDelta pattern: re-read from DB, apply delta
      for (const tray of traysToRefill) {
        const { data: freshTray, error: fetchErr } = await (supabase as any)
          .from('machine_trays')
          .select('current_stock, capacity')
          .eq('id', tray.id)
          .single()
        if (fetchErr) throw fetchErr

        const currentStock = (freshTray as any).current_stock
        const capacity = (freshTray as any).capacity
        const newStock = Math.min(capacity, currentStock + tray.fill_amount)

        if (newStock <= currentStock) continue

        const { error } = await (supabase as any)
          .from('machine_trays')
          .update({ current_stock: newStock })
          .eq('id', tray.id)
        if (error) throw error

        totalAdded += (newStock - currentStock)
      }

      // Log activity
      try {
        const { data: { session } } = await supabase.auth.getSession()
        const u = session?.user ?? null
        const fullName = [u?.user_metadata?.first_name, u?.user_metadata?.last_name]
          .filter(Boolean).join(' ').trim()
        const userDisplay = fullName || u?.email || null

        await (supabase as any).from('activity_log').insert({
          company_id: organization.value?.id,
          user_id: u?.id ?? null,
          entity_type: 'stock',
          entity_id: machine.id,
          action: 'stock_refill_tour',
          metadata: {
            machine_id: machine.id,
            machine_name: machine.name,
            trays_refilled: traysToRefill.length,
            total_added: totalAdded,
            _user_email: u?.email ?? null,
            _user_display: userDisplay,
          },
        })
      } catch {
        // activity log failure is non-critical
      }

      completedMachineIds.value = new Set([...completedMachineIds.value, machine.id])

      tourLog.value.push({
        machine_id: machine.id,
        machine_name: machine.name,
        trays_refilled: traysToRefill.length,
        total_added: totalAdded,
        skipped: false,
      })

      await advanceToNextMachine()
      saveTourState()
    } finally {
      confirmingRefill.value = false
    }
  }

  function skipMachine() {
    const machine = currentMachine.value
    if (machine) {
      completedMachineIds.value = new Set([...completedMachineIds.value, machine.id])
      tourLog.value.push({
        machine_id: machine.id,
        machine_name: machine.name,
        trays_refilled: 0,
        total_added: 0,
        skipped: true,
      })
    }
    advanceToNextMachine()
    saveTourState()
  }

  /** Navigate to a specific machine by index (for tab bar switching) */
  async function goToMachine(index: number) {
    if (index < 0 || index >= machines.value.length) return
    if (index === currentMachineIndex.value) return
    currentMachineIndex.value = index
    await loadTraysForCurrentMachine()
  }

  /** Check if a machine has been completed or skipped */
  function isMachineCompleted(machineId: string): boolean {
    return completedMachineIds.value.has(machineId)
  }

  /** Check if all machines are completed */
  const allMachinesCompleted = computed(() => {
    return machines.value.every(m => completedMachineIds.value.has(m.id))
  })

  async function advanceToNextMachine() {
    // Find the next uncompleted machine
    let nextIndex = -1
    for (let i = 0; i < machines.value.length; i++) {
      if (!completedMachineIds.value.has(machines.value[i].id)) {
        nextIndex = i
        break
      }
    }

    if (nextIndex === -1) {
      // All machines completed
      currentStep.value = 'summary'
      return
    }
    currentMachineIndex.value = nextIndex
    await loadTraysForCurrentMachine()
  }

  // ── Summary ────────────────────────────────────────────────────────────

  const tourSummary = computed(() => {
    const totalMachines = tourLog.value.length
    const machinesRefilled = tourLog.value.filter(e => !e.skipped).length
    const machinesSkipped = tourLog.value.filter(e => e.skipped).length
    const totalTraysRefilled = tourLog.value.reduce((sum, e) => sum + e.trays_refilled, 0)
    const totalItemsAdded = tourLog.value.reduce((sum, e) => sum + e.total_added, 0)
    return { totalMachines, machinesRefilled, machinesSkipped, totalTraysRefilled, totalItemsAdded }
  })

  // ── Persistence ──────────────────────────────────────────────────────────

  function saveTourState() {
    if (import.meta.server) return
    if (currentStep.value === 'packing') return // nothing to persist before tour starts

    const state: PersistedTourState = {
      currentStep: currentStep.value,
      machines: machines.value,
      currentMachineIndex: currentMachineIndex.value,
      selectedWarehouseId: selectedWarehouseId.value,
      packedQuantities: Array.from(packedQuantities.value.entries()).map(
        ([mid, pmap]) => [mid, Array.from(pmap.entries())] as [string, [string, number][]]
      ),
      completedMachineIds: Array.from(completedMachineIds.value),
      tourLog: tourLog.value,
      savedAt: Date.now(),
    }
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
    } catch {
      // storage full or unavailable — non-critical
    }
  }

  /** Restore a previously saved tour. Returns true if successful. */
  async function resumeTour(): Promise<boolean> {
    if (import.meta.server) return false
    try {
      const raw = localStorage.getItem(STORAGE_KEY)
      if (!raw) return false
      const state = JSON.parse(raw) as PersistedTourState
      if (Date.now() - state.savedAt > MAX_AGE_MS) {
        localStorage.removeItem(STORAGE_KEY)
        return false
      }
      if (state.currentStep !== 'refill' && state.currentStep !== 'summary') return false

      // Restore state
      currentStep.value = state.currentStep
      machines.value = state.machines
      currentMachineIndex.value = state.currentMachineIndex
      selectedWarehouseId.value = state.selectedWarehouseId
      completedMachineIds.value = new Set(state.completedMachineIds)
      tourLog.value = state.tourLog

      const pq = new Map<string, Map<string, number>>()
      for (const [mid, entries] of state.packedQuantities) {
        pq.set(mid, new Map(entries))
      }
      packedQuantities.value = pq

      // Load trays for current machine if in refill step
      if (state.currentStep === 'refill' && machines.value.length > 0) {
        await loadTraysForCurrentMachine()
      }

      return true
    } catch {
      return false
    }
  }

  function resetWizard() {
    currentStep.value = 'packing'
    machines.value = []
    currentMachineIndex.value = 0
    packedItems.value = new Map()
    packedQuantities.value = new Map()
    committedQuantities.value = new Map()
    completedMachineIds.value = new Set()
    currentTrays.value = []
    tourLog.value = []
    clearSavedTourState()
  }

  return {
    // State
    currentStep,
    machines,
    currentMachineIndex,
    selectedWarehouseId,
    warehouseStock,
    loading,
    tourStarting,
    confirmingRefill,
    packedItems,
    packedQuantities,
    currentTrays,
    currentTraysLoading,
    tourLog,

    // Computed
    currentMachine,
    machinesNeedingRefill,
    totalMachinesInTour,
    currentMachineNumber,
    tourSummary,
    allMachinesCompleted,
    completedMachineIds,

    // Packing
    isPacked,
    togglePacked,
    allPacked,
    getWarehouseAvailable,
    effectiveDeficit,
    isOutOfWarehouseStock,
    hasPartialStock,
    hasAnyPackedItems,
    effectiveStockHealth,

    // Actions
    initTour,
    loadWarehouseStock,
    startTour,
    loadTraysForCurrentMachine,
    adjustFillAmount,
    setFillAmount,
    confirmMachineRefill,
    skipMachine,
    goToMachine,
    isMachineCompleted,
    resetWizard,
    resumeTour,
  }
}
