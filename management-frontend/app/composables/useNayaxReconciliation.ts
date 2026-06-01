import { useState, useSupabaseClient } from '#imports'
import { fromZonedTime } from 'date-fns-tz'

/** Soft warning threshold: above this row count, surface a UI warning. */
export const MAX_ROWS_SOFT_WARN = 10000
/** Hard cap: parser rejects files with more rows than this. */
export const MAX_ROWS_HARD_CAP = 50000
/**
 * DP cell budget per machine for the sequence aligner. ~20M Int32 cells ≈ 80MB
 * transient — comfortably covers a very busy machine's billing period
 * (~4500×4500). Beyond this, `alignMachine` day-buckets that one machine.
 */
export const MAX_LCS_CELLS = 20_000_000

/**
 * Parse a Nayax "DD.MM.YYYY HH:MM:SS" timestamp interpreted in the given
 * IANA timezone and return its UTC equivalent as an ISO 8601 string.
 * Returns '' for malformed input.
 */
export function localDtToUtc(local: string, tz: string): string {
  const m = local.match(/^(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2}):(\d{2})$/)
  if (!m) return ''
  const [, dd, mm, yyyy, hh, mi, ss] = m
  // fromZonedTime takes an ISO-ish local string + IANA tz and returns the
  // Date at the corresponding UTC instant.
  const isoLocal = `${yyyy}-${mm}-${dd}T${hh}:${mi}:${ss}`
  const utc = fromZonedTime(isoLocal, tz)
  // Regex-valid inputs can still be semantically invalid (Feb 29 in a
  // non-leap year, hour 25, month 13, etc.) — fromZonedTime returns an
  // Invalid Date for those, and .toISOString() would throw RangeError.
  if (Number.isNaN(utc.getTime())) return ''
  return utc.toISOString()
}

/**
 * Extract the MDB selection (item) number from Nayax's
 * `Produktauswahl-Informationen` column. Format observed in the wild:
 *   "Product Name(NN  P.PP)"  e.g. "Mars Classic Single(39  1.20)"
 * Returns null when the parenthesis group is absent or malformed.
 */
export function parseSelectionInfo(raw: string): number | null {
  const m = raw.match(/\((\d+)\s+[\d.,]+\)/)
  if (!m) return null
  // Group 1 is mandatory in the pattern, so it is always defined when m matches.
  const n = parseInt(m[1]!, 10)
  return Number.isFinite(n) ? n : null
}

/**
 * Parse "Gesuchter Datumsbereich: DD.MM.YYYY HH:MM:SS - DD.MM.YYYY HH:MM:SS"
 * from row 1 of a Nayax export and convert both endpoints to UTC ISO 8601
 * strings. Returns null if the pattern is not present or malformed.
 */
export function parseTitleDateRange(
  title: string,
  tz: string,
): { fromUtc: string; toUtc: string } | null {
  const m = title.match(
    /(\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2}:\d{2})\s*-\s*(\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2}:\d{2})/,
  )
  if (!m) return null
  // Groups 1 and 2 are mandatory in the pattern, always defined when m matches.
  const fromUtc = localDtToUtc(m[1]!, tz)
  const toUtc = localDtToUtc(m[2]!, tz)
  if (!fromUtc || !toUtc) return null
  return { fromUtc, toUtc }
}

/**
 * Map the Nayax `Payment Method (Source)` column to our `sales.channel`
 * convention. Used when importing a Nayax row as a manual sale.
 */
export function derivedChannelFromPaymentSource(src: string): string {
  const s = src.trim()
  if (s === 'Cash') return 'cash'
  if (/^Credit Card\(/i.test(s)) return 'card'
  return 'nayax'
}

/**
 * Longest-common-subsequence alignment of two integer sequences.
 * Returns matched index pairs (ascending) plus the unmatched indices on each
 * side. Pure and deterministic; used to reconcile Nayax vs DB sale order
 * keyed on slot/item number. Time is NOT consulted — callers pre-sort.
 *
 * Suffix DP (dp[i][j] = LCS length of a[i:], b[j:]) with a front backtrack.
 * O(n·m) time and space; see `alignMachine` for the size guard.
 */
export function alignSequences(
  a: number[],
  b: number[],
): { pairs: Array<[number, number]>; aOnly: number[]; bOnly: number[] } {
  const n = a.length
  const m = b.length
  const w = m + 1
  const dp = new Int32Array((n + 1) * w)
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      if (a[i] === b[j]) {
        dp[i * w + j] = dp[(i + 1) * w + (j + 1)] + 1
      } else {
        const down = dp[(i + 1) * w + j]
        const right = dp[i * w + (j + 1)]
        dp[i * w + j] = down >= right ? down : right
      }
    }
  }
  const pairs: Array<[number, number]> = []
  const aOnly: number[] = []
  const bOnly: number[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      pairs.push([i, j]); i++; j++
    } else if (dp[(i + 1) * w + j] >= dp[i * w + (j + 1)]) {
      aOnly.push(i); i++
    } else {
      bOnly.push(j); j++
    }
  }
  while (i < n) { aOnly.push(i); i++ }
  while (j < m) { bOnly.push(j); j++ }
  return { pairs, aOnly, bOnly }
}

/**
 * Align one machine's Nayax sequence (a) against its DB sequence (b), keyed on
 * slot. `aDays`/`bDays` are the per-element **UTC** day strings ("YYYY-MM-DD"),
 * positionally paired with `aKeys`/`bKeys` (both pre-sorted by time).
 * Callers must derive these strings from UTC ISO timestamps; passing
 * browser-local day strings would bucket incorrectly at UTC midnight.
 *
 * Normally one `alignSequences` call. If the DP table would exceed `maxCells`
 * (a pathological single-machine upload), it falls back to aligning within
 * each UTC-day bucket and sets `bucketed: true`. Day-bucketing bounds cost but
 * cannot pair two equal slots that drifted across UTC midnight — an accepted
 * tradeoff that only ever applies to over-budget machines.
 */
export function alignMachine(
  aKeys: number[],
  aDays: string[],
  bKeys: number[],
  bDays: string[],
  maxCells: number,
): { pairs: Array<[number, number]>; aOnly: number[]; bOnly: number[]; bucketed: boolean } {
  const n = aKeys.length
  const m = bKeys.length
  if ((n + 1) * (m + 1) <= maxCells) {
    return { ...alignSequences(aKeys, bKeys), bucketed: false }
  }
  const dayKeys = [...new Set([...aDays, ...bDays])].sort()
  const pairs: Array<[number, number]> = []
  const aOnly: number[] = []
  const bOnly: number[] = []
  for (const day of dayKeys) {
    const aIdx: number[] = []
    for (let i = 0; i < n; i++) if (aDays[i] === day) aIdx.push(i)
    const bIdx: number[] = []
    for (let j = 0; j < m; j++) if (bDays[j] === day) bIdx.push(j)
    const sub = alignSequences(aIdx.map(i => aKeys[i]!), bIdx.map(j => bKeys[j]!))
    for (const [x, y] of sub.pairs) pairs.push([aIdx[x]!, bIdx[y]!])
    for (const x of sub.aOnly) aOnly.push(aIdx[x]!)
    for (const y of sub.bOnly) bOnly.push(bIdx[y]!)
  }
  return { pairs, aOnly, bOnly, bucketed: true }
}

/**
 * Widen an ISO date range by `seconds` on both ends, for the DB query only.
 * Lets a sale that drifted just across the file's start/end still load and
 * align. The strict range (for ghost classification) is left untouched.
 *
 * Precondition: `fromUtc` and `toUtc` must be valid ISO 8601 strings.
 * Invalid input yields `NaN` from `Date.parse`, and the subsequent
 * `toISOString()` call will throw a `RangeError`.
 */
export function bufferRange(
  fromUtc: string,
  toUtc: string,
  seconds: number,
): { gte: string; lte: string } {
  const pad = seconds * 1000
  return {
    gte: new Date(Date.parse(fromUtc) - pad).toISOString(),
    lte: new Date(Date.parse(toUtc) + pad).toISOString(),
  }
}

/** A single differences-table row: a Nayax gap or a DB phantom. */
export type DiffRow =
  | { kind: 'missing'; ts: string; payload: NayaxRow }
  | { kind: 'ghost'; ts: string; payload: DbSale }

/** Differences rows for one calendar day (browser-local), in chronological order. */
export interface DiffDayGroup { dayKey: string; rows: DiffRow[] }

/**
 * Merge the missing + ghost rows, sort chronologically (missing before ghost
 * on identical timestamps), and group into consecutive calendar-day buckets.
 *
 * The day key uses the BROWSER-LOCAL date (getFullYear/Month/Date) — the same
 * basis `formatDateTime`/`formatDate` render with (no `timeZone` option) — so a
 * row never groups under a day that differs from its displayed time.
 * dayKey is a browser-local `YYYY-MM-DD` key (month is 1-based, zero-padded).
 */
export function groupDifferencesByDay(
  missing: NayaxRow[],
  ghosts: DbSale[],
): DiffDayGroup[] {
  const rows: DiffRow[] = [
    ...missing.map(m => ({ kind: 'missing' as const, ts: m.utcDt, payload: m })),
    ...ghosts.map(g => ({ kind: 'ghost' as const, ts: g.created_at, payload: g })),
  ]
  rows.sort((a, b) => {
    const c = a.ts.localeCompare(b.ts)
    if (c !== 0) return c
    if (a.kind === b.kind) return 0
    return a.kind === 'missing' ? -1 : 1
  })
  const groups: DiffDayGroup[] = []
  for (const row of rows) {
    const d = new Date(row.ts)
    const dayKey = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
    const last = groups[groups.length - 1]
    if (last && last.dayKey === dayKey) last.rows.push(row)
    else groups.push({ dayKey, rows: [row] })
  }
  return groups
}

/** A single row parsed from the Nayax sales export. */
export interface NayaxRow {
  rowIndex: number          // 1-based index in the source file, for messages
  txId: string
  nayaxMachineId: string    // raw value from column 15
  machineName: string
  productGroup: string
  productName: string
  paymentSource: string     // "Cash" | "Credit Card(CLS)" | etc.
  priceGross: number        // rounded to 2dp
  itemNumber: number | null // parsed from column 14, null if regex fails
  selectionInfoRaw: string  // column 14 raw, kept for debug display
  localDt: string           // "DD.MM.YYYY HH:MM:SS" exactly as in file
  utcDt: string             // ISO 8601 UTC after timezone conversion
}

/** A sale row loaded from the DB for reconciliation. */
export interface DbSale {
  id: string
  created_at: string        // UTC from DB
  machine_id: string
  item_number: number | null
  item_price: number | null
  channel: string | null
  product_id: string | null
  product_name: string | null
}

export interface MatchPair {
  nayax: NayaxRow
  db: DbSale
  deltaSeconds: number      // db.created_at - nayax.utcDt (informational only now)
  priceDiffers: boolean     // round2(nayax.priceGross) !== round2(db.item_price)
}

export interface ReconResult {
  matched: MatchPair[]
  missingInDb: NayaxRow[]
  ghostInDb: DbSale[]
  unmapped: NayaxRow[]
  unparseable: NayaxRow[]
  fileDateRange: { fromUtc: string; toUtc: string } | null
  bucketedVmIds: string[]   // machines that hit the size guard (day-bucketed)
  settings: {
    timezone: string
    toleranceSeconds: number
  }
}

export type Step = 'upload' | 'mapping' | 'settings' | 'results'

/**
 * Compose the Nayax reconciliation workflow.
 *
 * The composable owns: the parsed Nayax rows, the per-company Nayax->VM
 * mapping cache, the matching settings, the loaded DB sales, and the
 * computed reconciliation result. The wizard page and child components
 * receive reactive refs from this composable and emit intent events to
 * trigger its actions.
 */
export function useNayaxReconciliation() {
  // IMPORTANT: workflow state uses `useState(key, ...)` so the page and every
  // child component share the same refs. A plain `ref(...)` would give each
  // call site its own isolated state — the wizard would not work. This
  // mirrors the pattern in `useMachines` (see `useState<VendingMachine[]>('machines', ...)`).
  const file = useState<File | null>('nayax-recon-file', () => null)
  const rawRows = useState<NayaxRow[]>('nayax-recon-raw-rows', () => [])
  const dbSales = useState<DbSale[]>('nayax-recon-dbSales', () => [])
  // Use a plain object (Record) rather than Map: Vue's reactive system
  // observes object property mutations (`mapping.value[k] = v`,
  // `delete mapping.value[k]`) but not `Map.set` / `Map.delete`.
  const mapping = useState<Record<string, string>>('nayax-recon-mapping', () => ({}))
  const settings = useState('nayax-recon-settings', () => ({
    timezone: 'Europe/Berlin',
    toleranceSeconds: 10,
    fromUtc: '',
    toUtc: '',
  }))
  const result = useState<ReconResult | null>('nayax-recon-result', () => null)
  const step = useState<Step>('nayax-recon-step', () => 'upload' as Step)
  const parsing = useState<boolean>('nayax-recon-parsing', () => false)
  const matching = useState<boolean>('nayax-recon-matching', () => false)
  const importing = useState<boolean>('nayax-recon-importing', () => false)
  const deleting = useState<boolean>('nayax-recon-deleting', () => false)
  const error = useState<string>('nayax-recon-error', () => '')

  async function parseFile(f: File): Promise<void> {
    parsing.value = true
    error.value = ''
    rawRows.value = []
    file.value = f

    try {
      // Lazy-import xlsx so the dev-bundle is only paid when we actually
      // open the reconciliation page.
      const XLSX = await import('xlsx')
      const buffer = await f.arrayBuffer()
      const wb = XLSX.read(buffer, { type: 'array' })
      const sheetName = wb.SheetNames[0]
      if (!sheetName) throw new Error('parser.noSheet')
      const sheet = wb.Sheets[sheetName]

      // Read the raw matrix so we can grab the title row directly.
      const matrix = XLSX.utils.sheet_to_json<unknown[]>(sheet, {
        header: 1,
        defval: null,
        raw: false,
      })
      if (matrix.length < 2) throw new Error('parser.empty')

      // Row 0 = title cell (with the date range).
      const titleCell = String(matrix[0]?.[0] ?? '')
      const range = parseTitleDateRange(titleCell, settings.value.timezone)
      if (range) {
        settings.value.fromUtc = range.fromUtc
        settings.value.toUtc = range.toUtc
      }

      // Row 1 = headers.
      const headers = (matrix[1] ?? []).map(v => String(v ?? '').trim())
      const idx = {
        txId:           headers.indexOf('Transaktions-ID'),
        currency:       headers.indexOf('Währung'),
        machineName:    headers.indexOf('Maschinenname'),
        productGroup:   headers.indexOf('Produktgruppe'),
        paymentSource:  headers.indexOf('Payment Method (Source)'),
        productName:    headers.indexOf('Produktname'),
        machineDt:      headers.indexOf('Maschinen-Begleichszeit'),
        amount:         headers.indexOf('Zu begleichender Wert'),
        selectionInfo:  headers.indexOf('Produktauswahl-Informationen'),
        nayaxId:        headers.indexOf('Maschinen-ID'),
      }
      for (const [k, v] of Object.entries(idx)) {
        if (v < 0) throw new Error(`parser.missingHeader.${k}`)
      }

      // Rows 2..end = data + a final "Total" row.
      const data = matrix.slice(2)
      if (data.length > MAX_ROWS_HARD_CAP) {
        throw new Error('parser.tooLarge')
      }

      const rows: NayaxRow[] = []
      data.forEach((row, i) => {
        const txId = String(row[idx.txId] ?? '').trim()
        const currency = String(row[idx.currency] ?? '').trim()
        // The footer is empty in Transaktions-ID (and Währung holds 'Total').
        if (!txId || currency === 'Total') return

        const localDt = String(row[idx.machineDt] ?? '').trim()
        const selectionInfoRaw = String(row[idx.selectionInfo] ?? '').trim()
        const priceGross = roundTo2(Number(row[idx.amount] ?? 0))

        rows.push({
          rowIndex: i + 3,                       // 1-based source row
          txId,
          nayaxMachineId: String(row[idx.nayaxId] ?? '').trim(),
          machineName: String(row[idx.machineName] ?? '').trim(),
          productGroup: String(row[idx.productGroup] ?? '').trim(),
          productName: String(row[idx.productName] ?? '').trim(),
          paymentSource: String(row[idx.paymentSource] ?? '').trim(),
          priceGross,
          itemNumber: parseSelectionInfo(selectionInfoRaw),
          selectionInfoRaw,
          localDt,
          utcDt: localDtToUtc(localDt, settings.value.timezone),
        })
      })

      rawRows.value = rows
    } catch (e: unknown) {
      error.value = e instanceof Error ? e.message : 'parser.unknown'
    } finally {
      parsing.value = false
    }
  }

  function roundTo2(n: number): number {
    return Math.round(n * 100) / 100
  }

  async function loadMappingForCompany(): Promise<void> {
    const supabase = useSupabaseClient()
    const { data, error: err } = await supabase
      .from('vendingMachine')
      .select('id, nayax_machine_id')
      .not('nayax_machine_id', 'is', null)
    if (err) throw err
    const m: Record<string, string> = {}
    for (const row of (data ?? []) as { id: string; nayax_machine_id: string }[]) {
      m[row.nayax_machine_id] = row.id
    }
    mapping.value = m
  }

  function detectUnmappedIds(): string[] {
    const seen = new Set<string>()
    for (const r of rawRows.value) {
      if (r.nayaxMachineId && !(r.nayaxMachineId in mapping.value)) {
        seen.add(r.nayaxMachineId)
      }
    }
    return [...seen]
  }

  async function saveMapping(nayaxId: string, vmId: string | null): Promise<void> {
    const supabase = useSupabaseClient()
    if (vmId == null) {
      // "Skip for this run" — do not write, just drop from local mapping
      const { [nayaxId]: _, ...rest } = mapping.value
      mapping.value = rest
      return
    }
    const { error: err } = await supabase
      .from('vendingMachine')
      .update({ nayax_machine_id: nayaxId } as any)
      .eq('id', vmId)
    if (err) throw err
    // Update the local cache so subsequent matching uses the new mapping.
    mapping.value = { ...mapping.value, [nayaxId]: vmId }
  }

  async function loadDbSales(): Promise<void> {
    const supabase = useSupabaseClient()
    const { fromUtc, toUtc } = settings.value
    if (!fromUtc || !toUtc) {
      throw new Error('reconcile.noDateRange')
    }
    const machineIds = [...new Set(Object.values(mapping.value))]
    if (machineIds.length === 0) {
      dbSales.value = []
      return
    }
    // Paginate to avoid PostgREST's max_rows=1000 silent truncation.
    // Without pagination, a busy operator with >1000 sales in the date
    // range would see false "missing in DB" rows (because the truncated
    // tail of dbSales hides real matches), which would in turn create
    // duplicate sales on bulk import.
    const PAGE = 1000
    const all: DbSale[] = []
    let from = 0
    while (true) {
      const { data, error: err } = await supabase
        .from('sales')
        .select('id, created_at, machine_id, item_number, item_price, channel, product_id, products(name)')
        .gte('created_at', fromUtc)
        .lte('created_at', toUtc)
        .in('machine_id', machineIds)
        .order('created_at', { ascending: true })
        .range(from, from + PAGE - 1)
      if (err) throw err
      const rows = (data ?? []) as any[]
      if (rows.length === 0) break
      for (const row of rows) {
        all.push({
          id: row.id,
          created_at: row.created_at,
          machine_id: row.machine_id,
          item_number: row.item_number,
          item_price: row.item_price,
          channel: row.channel,
          product_id: row.product_id,
          product_name: row.products?.name ?? null,
        })
      }
      if (rows.length < PAGE) break
      from += PAGE
    }
    dbSales.value = all
  }

  function runMatch(): void {
    matching.value = true
    try {
      const tz = settings.value.timezone
      const fromMs = Date.parse(settings.value.fromUtc)
      const toMs = Date.parse(settings.value.toUtc)

      // Pre-filter: unmapped + unparseable (unchanged), then group eligible
      // Nayax rows by mapped VM.
      const unmapped: NayaxRow[] = []
      const unparseable: NayaxRow[] = []
      const eligibleByVm = new Map<string, NayaxRow[]>()
      for (const n of rawRows.value) {
        if (!n.nayaxMachineId || !(n.nayaxMachineId in mapping.value)) { unmapped.push(n); continue }
        if (n.itemNumber == null || n.priceGross <= 0) { unparseable.push(n); continue }
        const vmId = mapping.value[n.nayaxMachineId]!
        const list = eligibleByVm.get(vmId)
        if (list) list.push(n)
        else eligibleByVm.set(vmId, [n])
      }

      // Group loaded DB sales (incl. the ±buffer rows) by machine.
      const dbByVm = new Map<string, DbSale[]>()
      for (const s of dbSales.value) {
        if (s.machine_id == null) continue
        const list = dbByVm.get(s.machine_id)
        if (list) list.push(s)
        else dbByVm.set(s.machine_id, [s])
      }

      const matched: MatchPair[] = []
      const missingInDb: NayaxRow[] = []
      const ghostInDb: DbSale[] = []
      const bucketedVmIds: string[] = []

      const vmIds = new Set<string>([...eligibleByVm.keys(), ...dbByVm.keys()])
      for (const vmId of vmIds) {
        const aRows = (eligibleByVm.get(vmId) ?? []).slice()
          .sort((x, y) => x.utcDt.localeCompare(y.utcDt))
        const bRows = (dbByVm.get(vmId) ?? []).slice()
          .sort((x, y) => x.created_at.localeCompare(y.created_at))

        const aKeys = aRows.map(r => r.itemNumber as number)   // non-null (eligible)
        const bKeys = bRows.map(r => r.item_number ?? -1)      // null slot matches nothing
        const aDays = aRows.map(r => r.utcDt.slice(0, 10))
        const bDays = bRows.map(r => r.created_at.slice(0, 10))

        const { pairs, aOnly, bOnly, bucketed } = alignMachine(aKeys, aDays, bKeys, bDays, MAX_LCS_CELLS)
        if (bucketed) bucketedVmIds.push(vmId)

        for (const [ai, bi] of pairs) {
          const nrow = aRows[ai]!
          const srow = bRows[bi]!
          const delta = (Date.parse(srow.created_at) - Date.parse(nrow.utcDt)) / 1000
          const priceDiffers = srow.item_price == null
            || roundTo2(srow.item_price) !== roundTo2(nrow.priceGross)
          matched.push({ nayax: nrow, db: srow, deltaSeconds: delta, priceDiffers })
        }
        for (const ai of aOnly) missingInDb.push(aRows[ai]!)
        for (const bi of bOnly) {
          const srow = bRows[bi]!
          const t = Date.parse(srow.created_at)
          if (t >= fromMs && t <= toMs) ghostInDb.push(srow)   // strict range only
        }
      }

      result.value = {
        matched,
        missingInDb,
        ghostInDb,
        unmapped,
        unparseable,
        bucketedVmIds,
        fileDateRange: settings.value.fromUtc && settings.value.toUtc
          ? { fromUtc: settings.value.fromUtc, toUtc: settings.value.toUtc }
          : null,
        settings: {
          timezone: tz,
          toleranceSeconds: settings.value.toleranceSeconds,
        },
      }
    } finally {
      matching.value = false
    }
  }
  /**
   * Write an audit log entry tagged with `source: 'nayax_reconciliation'`
   * so the activity feed can distinguish Nayax-driven actions from manual
   * sale-add / sale-delete on /machines/[id]. Mirrors the `logSaleActivity`
   * helper in `pages/machines/[id].vue`. Errors are swallowed — auditing
   * is best-effort, the underlying RPC has already succeeded.
   */
  async function logNayaxActivity(
    action: 'sale_inserted' | 'sale_deleted',
    entityId: string | null,
    metadata: Record<string, unknown>,
  ): Promise<void> {
    try {
      const supabase = useSupabaseClient()
      const { data: { session } } = await supabase.auth.getSession()
      const u = session?.user ?? null
      const meta = (u?.user_metadata ?? {}) as { first_name?: string; last_name?: string }
      const fullName = [meta.first_name, meta.last_name].filter(Boolean).join(' ').trim()
      const userDisplay = fullName || u?.email || null
      const { organization } = useOrganization()
      if (!organization.value?.id) return
      await (supabase as any).from('activity_log').insert({
        company_id: organization.value.id,
        user_id: u?.id ?? null,
        entity_type: 'sale',
        entity_id: entityId,
        action,
        metadata: {
          ...metadata,
          source: 'nayax_reconciliation',
          _user_email: u?.email ?? null,
          _user_display: userDisplay,
        },
      })
    } catch (err) {
      console.warn('nayax activity_log insert failed:', err)
    }
  }

  async function bulkImportMissing(
    rows: NayaxRow[],
  ): Promise<{ imported: number; errors: string[] }> {
    importing.value = true
    const errors: string[] = []
    let imported = 0
    try {
      const supabase = useSupabaseClient()
      for (const n of rows) {
        const vmId = mapping.value[n.nayaxMachineId]
        if (!vmId || n.itemNumber == null) {
          errors.push(`row ${n.rowIndex}: cannot import (unmapped or unparseable)`)
          continue
        }
        const channel = derivedChannelFromPaymentSource(n.paymentSource)
        const { data, error: err } = await (supabase as any).rpc('insert_manual_sale', {
          p_machine_id: vmId,
          p_item_number: n.itemNumber,
          p_item_price: n.priceGross,
          p_channel: channel,
          p_created_at: n.utcDt,
        })
        if (err) {
          errors.push(`row ${n.rowIndex} (${n.txId}): ${err.message ?? err}`)
          continue
        }
        imported++
        // Best-effort activity-log entry. The RPC response is sometimes a
        // JSON string, sometimes a parsed object — match the existing
        // pages/machines/[id].vue handling.
        const inserted = data ? (typeof data === 'string' ? JSON.parse(data) : data) : null
        await logNayaxActivity('sale_inserted', inserted?.id ?? null, {
          machine_id: vmId,
          item_number: n.itemNumber,
          item_price: n.priceGross,
          channel,
          sale_created_at: n.utcDt,
          nayax_tx_id: n.txId,
        })
      }
      // Re-load DB sales so subsequent `runMatch` reflects new rows.
      // Wrap separately — a failure here shouldn't lose the per-row success
      // info. The user can still hit "Re-run" to refresh manually.
      try {
        await loadDbSales()
        runMatch()
      } catch (e: unknown) {
        errors.push(`refresh after import: ${e instanceof Error ? e.message : String(e)}`)
      }
    } finally {
      importing.value = false
    }
    return { imported, errors }
  }

  async function deleteGhost(saleId: string): Promise<void> {
    deleting.value = true
    try {
      const supabase = useSupabaseClient()
      // Capture the sale's fields for the audit log before deletion.
      const ghost = dbSales.value.find(s => s.id === saleId)
      const { error: err } = await (supabase as any).rpc('delete_sale_and_restore_stock', {
        p_sale_id: saleId,
      })
      if (err) throw err
      await logNayaxActivity('sale_deleted', saleId, {
        machine_id: ghost?.machine_id ?? null,
        item_number: ghost?.item_number ?? null,
        item_price: ghost?.item_price ?? null,
        channel: ghost?.channel ?? null,
        sale_created_at: ghost?.created_at ?? null,
      })
      // Refresh state
      await loadDbSales()
      runMatch()
    } finally {
      deleting.value = false
    }
  }
  function exportDiffCsv(): string {
    if (!result.value) return ''
    const cols = [
      'bucket','nayax_time_local','nayax_time_utc','db_time_utc','delta_seconds',
      'machine_name','slot','product','price','payment_source','channel',
      'nayax_tx_id','db_sale_id',
    ]
    const esc = (v: unknown): string => {
      if (v == null) return ''
      const s = String(v)
      if (s.includes(',') || s.includes('"') || s.includes('\n')) {
        return `"${s.replace(/"/g, '""')}"`
      }
      return s
    }
    const lines: string[] = [cols.join(',')]
    const machineNameById = new Map<string, string>()
    for (const [nayaxId, vmId] of Object.entries(mapping.value)) {
      const n = rawRows.value.find(r => r.nayaxMachineId === nayaxId)
      if (n) machineNameById.set(vmId, n.machineName)
    }
    for (const m of result.value.matched) {
      lines.push([
        'matched',
        m.nayax.localDt,
        m.nayax.utcDt,
        m.db.created_at,
        m.deltaSeconds.toFixed(2),
        m.nayax.machineName,
        m.nayax.itemNumber,
        m.db.product_name ?? m.nayax.productName,
        m.nayax.priceGross.toFixed(2),
        m.nayax.paymentSource,
        m.db.channel ?? '',
        m.nayax.txId,
        m.db.id,
      ].map(esc).join(','))
    }
    for (const n of result.value.missingInDb) {
      lines.push([
        'missing_in_db',
        n.localDt, n.utcDt, '', '',
        n.machineName, n.itemNumber, n.productName,
        n.priceGross.toFixed(2), n.paymentSource, '',
        n.txId, '',
      ].map(esc).join(','))
    }
    for (const s of result.value.ghostInDb) {
      lines.push([
        'ghost_in_db',
        '', '', s.created_at, '',
        machineNameById.get(s.machine_id) ?? '',
        s.item_number, s.product_name ?? '',
        s.item_price?.toFixed(2) ?? '', '',
        s.channel ?? '',
        '', s.id,
      ].map(esc).join(','))
    }
    return lines.join('\n')
  }
  function reset(): void {
    file.value = null
    rawRows.value = []
    dbSales.value = []
    result.value = null
    step.value = 'upload'
    error.value = ''
  }

  return {
    file, rawRows, dbSales, mapping, settings, result, step,
    parsing, matching, importing, deleting, error,
    parseFile, loadMappingForCompany, detectUnmappedIds, saveMapping,
    loadDbSales, runMatch, bulkImportMissing, deleteGhost, exportDiffCsv,
    reset,
  }
}
