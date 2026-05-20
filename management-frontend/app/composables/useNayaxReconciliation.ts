import { useState, useSupabaseClient } from '#imports'
import { fromZonedTime } from 'date-fns-tz'

/** Soft warning threshold: above this row count, surface a UI warning. */
export const MAX_ROWS_SOFT_WARN = 10000
/** Hard cap: parser rejects files with more rows than this. */
export const MAX_ROWS_HARD_CAP = 50000

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
  deltaSeconds: number      // db.created_at - nayax.utcDt
}

export interface ReconResult {
  matched: MatchPair[]
  missingInDb: NayaxRow[]
  ghostInDb: DbSale[]
  unmapped: NayaxRow[]
  unparseable: NayaxRow[]
  fileDateRange: { fromUtc: string; toUtc: string } | null
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
    // Join products so we can show a name in the ghost table.
    const { data, error: err } = await supabase
      .from('sales')
      .select('id, created_at, machine_id, item_number, item_price, channel, product_id, products(name)')
      .gte('created_at', fromUtc)
      .lte('created_at', toUtc)
      .in('machine_id', machineIds)
      .order('created_at', { ascending: true })
    if (err) throw err
    dbSales.value = (data ?? []).map((row: any) => ({
      id: row.id,
      created_at: row.created_at,
      machine_id: row.machine_id,
      item_number: row.item_number,
      item_price: row.item_price,
      channel: row.channel,
      product_id: row.product_id,
      product_name: row.products?.name ?? null,
    }))
  }

  // Stubs filled in by later tasks
  function runMatch(): void { throw new Error('not impl') }
  async function bulkImportMissing(_rows: NayaxRow[]): Promise<{ imported: number; errors: string[] }> { throw new Error('not impl') }
  async function deleteGhost(_saleId: string): Promise<void> { throw new Error('not impl') }
  function exportDiffCsv(): string { throw new Error('not impl') }
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
