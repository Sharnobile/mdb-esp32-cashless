import { useState } from '#imports'
import { fromZonedTime } from 'date-fns-tz'

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

  // Stubs filled in by later tasks
  async function parseFile(_f: File): Promise<void> { throw new Error('not impl') }
  async function loadMappingForCompany(): Promise<void> { throw new Error('not impl') }
  function detectUnmappedIds(): string[] { throw new Error('not impl') }
  async function saveMapping(_nayaxId: string, _vmId: string | null): Promise<void> { throw new Error('not impl') }
  async function loadDbSales(): Promise<void> { throw new Error('not impl') }
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
