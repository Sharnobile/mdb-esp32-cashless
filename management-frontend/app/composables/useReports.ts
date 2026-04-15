import { useSupabaseClient } from '#imports'

export interface ReportSale {
  id: string
  created_at: string
  machine_name: string
  machine_id: string
  item_number: number
  product_id: string | null
  product_name: string | null
  category_name: string | null
  item_price: number
  tax_rate_snapshot: number | null
  tax_amount: number | null
  price_net: number | null
  channel: string | null
}

function germanNumber(n: number | null | undefined, decimals = 2): string {
  if (n == null) return ''
  return n.toFixed(decimals).replace('.', ',')
}

function datevDate(isoDate: string): string {
  const d = new Date(isoDate)
  const day = String(d.getDate()).padStart(2, '0')
  const month = String(d.getMonth() + 1).padStart(2, '0')
  return `${day}${month}`
}

function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

/** Convert string to Windows-1252 bytes (best-effort, replaces unmappable chars with ?) */
function toWindows1252(str: string): Uint8Array {
  const bytes: number[] = []
  for (let i = 0; i < str.length; i++) {
    const code = str.charCodeAt(i)
    if (code <= 0xFF) {
      bytes.push(code)
    } else {
      // Common German chars that map to Windows-1252
      const map: Record<number, number> = {
        0x20AC: 0x80, // €
        0x201E: 0x84, // „
        0x2026: 0x85, // …
        0x2013: 0x96, // –
        0x2014: 0x97, // —
        0x201C: 0x93, // "
        0x201D: 0x94, // "
      }
      bytes.push(map[code] ?? 0x3F) // ? for unmappable
    }
  }
  return new Uint8Array(bytes)
}

export function useReports() {
  const sales = useState<ReportSale[]>('report-sales', () => [])
  const loading = ref(false)

  const now = new Date()
  const dateFrom = ref(new Date(now.getFullYear(), now.getMonth(), 1).toISOString().split('T')[0])
  const dateTo = ref(now.toISOString().split('T')[0])

  async function fetchReportData() {
    loading.value = true
    try {
      const supabase = useSupabaseClient()

      // Fetch sales with machine name via join
      // Fetch sales with product (via snapshotted product_id FK) and machine name
      const { data, error } = await supabase
        .from('sales')
        .select(`
          id, created_at, item_price, item_number, channel,
          tax_rate_snapshot, tax_amount, price_net,
          machine_id, product_id,
          vendingMachine!inner(name),
          products(name, image_path, product_category(name))
        `)
        .gte('created_at', `${dateFrom.value}T00:00:00`)
        .lte('created_at', `${dateTo.value}T23:59:59`)
        .order('created_at', { ascending: false })
        .limit(10000)

      if (error) throw error

      const rawSales = (data ?? []) as any[]

      // Fallback: batch fetch tray → product for old sales with NULL product_id
      const salesWithoutProduct = rawSales.filter(s => !s.product_id && s.machine_id)
      const fallbackMachineIds = [...new Set(salesWithoutProduct.map(s => s.machine_id))]

      let trayMap = new Map<string, { product_name: string | null; category_name: string | null }>()
      if (fallbackMachineIds.length > 0) {
        const { data: trays } = await supabase
          .from('machine_trays')
          .select('machine_id, item_number, products(name, product_category(name))')
          .in('machine_id', fallbackMachineIds)

        for (const tray of (trays ?? []) as any[]) {
          const key = `${tray.machine_id}:${tray.item_number}`
          trayMap.set(key, {
            product_name: tray.products?.name ?? null,
            category_name: tray.products?.product_category?.name ?? null,
          })
        }
      }

      sales.value = rawSales.map(s => {
        // Prefer product from snapshotted FK join, fallback to tray lookup for old sales
        const trayInfo = !s.product_id ? trayMap.get(`${s.machine_id}:${s.item_number}`) : null
        return {
          id: s.id,
          created_at: s.created_at,
          machine_name: s.vendingMachine?.name ?? '—',
          machine_id: s.machine_id ?? '',
          item_number: s.item_number,
          product_id: s.product_id ?? null,
          product_name: s.products?.name ?? trayInfo?.product_name ?? null,
          category_name: s.products?.product_category?.name ?? trayInfo?.category_name ?? null,
          item_price: s.item_price,
          tax_rate_snapshot: s.tax_rate_snapshot,
          tax_amount: s.tax_amount,
          price_net: s.price_net,
          channel: s.channel,
        }
      })
    } finally {
      loading.value = false
    }
  }

  function exportSimpleCsv() {
    if (filteredSales.value.length === 0) return

    const headers = [
      'Datum', 'Uhrzeit', 'Automat', 'Automaten-ID', 'Tray',
      'Produkt', 'Kategorie', 'Brutto (EUR)', 'MwSt. (%)',
      'MwSt. (EUR)', 'Netto (EUR)', 'Bezahlart',
    ]

    const rows = filteredSales.value.map(s => {
      const d = new Date(s.created_at)
      const date = `${String(d.getDate()).padStart(2, '0')}.${String(d.getMonth() + 1).padStart(2, '0')}.${d.getFullYear()}`
      const time = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
      const taxPct = s.tax_rate_snapshot != null ? germanNumber(s.tax_rate_snapshot * 100, 1) : ''

      return [
        date,
        time,
        s.machine_name,
        s.machine_id,
        String(s.item_number),
        s.product_name ?? '',
        s.category_name ?? '',
        germanNumber(s.item_price),
        taxPct,
        germanNumber(s.tax_amount),
        germanNumber(s.price_net),
        s.channel ?? '',
      ]
    })

    const csv = [
      headers.join(';'),
      ...rows.map(r => r.map(cell => `"${cell}"`).join(';')),
    ].join('\r\n')

    // UTF-8 BOM for Excel
    const bom = '\uFEFF'
    const blob = new Blob([bom + csv], { type: 'text/csv;charset=utf-8' })
    const fromStr = dateFrom.value.replace(/-/g, '')
    const toStr = dateTo.value.replace(/-/g, '')
    downloadBlob(blob, `Verkaufsbericht_${fromStr}_${toStr}.csv`)
  }

  function exportDatev() {
    if (filteredSales.value.length === 0) return

    const fromStr = dateFrom.value.replace(/-/g, '')
    const toStr = dateTo.value.replace(/-/g, '')
    const fromDate = new Date(dateFrom.value)
    const toDate = new Date(dateTo.value)

    // DATEV EXTF row 1: metadata
    // Format: "EXTF";version;category;format_name;format_version;generated_at;;;;;;
    //         advisor_nr;client_nr;fiscal_year_start;account_length;
    //         date_from;date_to;description;dictation_short;booking_type;purpose;
    //         lock;currency;...
    const now = new Date()
    const generatedAt = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}${String(now.getSeconds()).padStart(2, '0')}000`

    const row1Fields = [
      '"EXTF"', '700', '21', '"Buchungsstapel"', '12', generatedAt,
      '', '', '', '', '', '',
      '""', '""', // advisor_nr, client_nr (user fills in)
      `${fromDate.getFullYear()}0101`, // fiscal year start
      '4', // account length (SKR03 = 4 digits)
      `${fromStr}`, `${toStr}`,
      '"Automatenverkäufe"', // description
      '""', // dictation_short
      '""', // booking_type
      '0', // purpose (0 = undefined)
      '0', // lock
      '"EUR"', // currency
      '', '', '', '',
    ]
    const row1 = row1Fields.join(';')

    // Row 2: column headers (key fields only, rest empty)
    // DATEV has 127 columns — we fill the mandatory ones
    const headers = [
      'Umsatz (ohne Soll/Haben-Kz)', 'Soll/Haben-Kennzeichen', 'WKZ Umsatz',
      'Kurs', 'Basis-Umsatz', 'WKZ Basis-Umsatz',
      'Konto', 'Gegenkonto (ohne BU-Schlüssel)', 'BU-Schlüssel',
      'Belegdatum', 'Belegfeld 1', 'Belegfeld 2',
      'Skonto', 'Buchungstext',
      // Columns 15-116 are empty for our use case
      ...Array(102).fill(''),
      'Leistungsdatum', // Column 117
      ...Array(10).fill(''),
    ]
    const row2 = headers.map(h => h ? `"${h}"` : '""').join(';')

    // Data rows
    const dataRows = filteredSales.value.map(s => {
      const amount = germanNumber(s.item_price)
      const taxRate = s.tax_rate_snapshot

      // Gegenkonto based on tax rate (SKR03)
      let gegenkonto = '8400' // Default: Erlöse 19%
      let buSchluessel = ''
      if (taxRate != null) {
        if (Math.abs(taxRate - 0.07) < 0.001) {
          gegenkonto = '8300' // Erlöse 7%
          buSchluessel = '8'
        } else if (Math.abs(taxRate - 0.19) < 0.001) {
          gegenkonto = '8400' // Erlöse 19%
          buSchluessel = '9'
        }
        // Other rates: leave BU-Schlüssel empty, accountant can map
      }

      const belegdatum = datevDate(s.created_at)
      const belegfeld1 = s.id.substring(0, 12)
      const buchungstext = `${s.machine_name} Tray ${s.item_number}`.substring(0, 60)

      const leistungsdatum = (() => {
        const d = new Date(s.created_at)
        return `${String(d.getDate()).padStart(2, '0')}${String(d.getMonth() + 1).padStart(2, '0')}${d.getFullYear()}`
      })()

      const fields = [
        amount,       // Umsatz
        '"S"',        // Soll (debit — revenue booking)
        '"EUR"',      // WKZ
        '', '', '',   // Kurs, Basis-Umsatz, WKZ Basis-Umsatz
        '"10000"',    // Konto (Kasse/Bank)
        `"${gegenkonto}"`,  // Gegenkonto
        buSchluessel ? `"${buSchluessel}"` : '""', // BU-Schlüssel
        `"${belegdatum}"`,  // Belegdatum
        `"${belegfeld1}"`,  // Belegfeld 1
        '""',         // Belegfeld 2
        '',           // Skonto
        `"${buchungstext}"`, // Buchungstext
        // Columns 15-116 empty
        ...Array(102).fill('""'),
        `"${leistungsdatum}"`, // Leistungsdatum (column 117)
        ...Array(10).fill('""'),
      ]
      return fields.join(';')
    })

    const content = [row1, row2, ...dataRows].join('\r\n')
    const encoded = toWindows1252(content)
    const blob = new Blob([encoded], { type: 'text/csv;charset=windows-1252' })
    downloadBlob(blob, `EXTF_Buchungsstapel_${fromStr}_${toStr}.csv`)
  }

  /** Payment method filters */
  const channelFilters = ref<Record<string, boolean>>({
    cashless: true,
    cash: true,
    card: true,
    mqtt: true,
  })

  /** All unique channels in current dataset */
  const availableChannels = computed(() => {
    const channels = new Set<string>()
    for (const s of sales.value) {
      if (s.channel) channels.add(s.channel)
    }
    return [...channels].sort()
  })

  /** Filtered sales based on channel toggles */
  const filteredSales = computed(() => {
    return sales.value.filter(s => {
      const ch = s.channel ?? 'cashless'
      return channelFilters.value[ch] !== false
    })
  })

  /** Summary totals (based on filtered sales) */
  const summary = computed(() => {
    let totalGross = 0
    let totalTax = 0
    let totalNet = 0
    for (const s of filteredSales.value) {
      totalGross += s.item_price ?? 0
      totalTax += s.tax_amount ?? 0
      totalNet += s.price_net ?? 0
    }
    return {
      count: filteredSales.value.length,
      totalGross,
      totalTax,
      totalNet,
      avgPerSale: filteredSales.value.length > 0 ? totalGross / filteredSales.value.length : 0,
    }
  })

  /** VAT breakdown by tax rate (based on filtered sales) */
  const vatBreakdown = computed(() => {
    const map = new Map<string, { rate: number; gross: number; net: number; tax: number; count: number }>()

    for (const s of filteredSales.value) {
      const rate = s.tax_rate_snapshot
      const key = rate != null ? `${(rate * 100).toFixed(2)}` : 'unknown'

      let entry = map.get(key)
      if (!entry) {
        entry = { rate: rate ?? 0, gross: 0, net: 0, tax: 0, count: 0 }
        map.set(key, entry)
      }
      entry.gross += s.item_price ?? 0
      entry.net += s.price_net ?? 0
      entry.tax += s.tax_amount ?? 0
      entry.count += 1
    }

    return [...map.values()].sort((a, b) => b.rate - a.rate)
  })

  /** Monthly summary export — one row per machine per month with VAT split */
  function exportMonthlySummary() {
    if (filteredSales.value.length === 0) return

    // Group by machine + month
    const map = new Map<string, {
      month: string
      machine_name: string
      machine_id: string
      gross: number
      gross_standard: number
      net_standard: number
      tax_standard: number
      gross_reduced: number
      net_reduced: number
      tax_reduced: number
      gross_other: number
      net_other: number
      tax_other: number
      cash: number
      cashless: number
      count: number
    }>()

    for (const s of filteredSales.value) {
      const d = new Date(s.created_at)
      const month = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
      const key = `${month}:${s.machine_id}`

      let entry = map.get(key)
      if (!entry) {
        entry = {
          month,
          machine_name: s.machine_name,
          machine_id: s.machine_id,
          gross: 0,
          gross_standard: 0, net_standard: 0, tax_standard: 0,
          gross_reduced: 0, net_reduced: 0, tax_reduced: 0,
          gross_other: 0, net_other: 0, tax_other: 0,
          cash: 0, cashless: 0,
          count: 0,
        }
        map.set(key, entry)
      }

      entry.gross += s.item_price ?? 0
      entry.count += 1

      // Payment method
      const ch = s.channel ?? 'cashless'
      if (ch === 'cash') {
        entry.cash += s.item_price ?? 0
      } else {
        entry.cashless += s.item_price ?? 0
      }

      // VAT split
      const rate = s.tax_rate_snapshot
      if (rate != null && Math.abs(rate - 0.19) < 0.001) {
        entry.gross_standard += s.item_price ?? 0
        entry.net_standard += s.price_net ?? 0
        entry.tax_standard += s.tax_amount ?? 0
      } else if (rate != null && Math.abs(rate - 0.07) < 0.001) {
        entry.gross_reduced += s.item_price ?? 0
        entry.net_reduced += s.price_net ?? 0
        entry.tax_reduced += s.tax_amount ?? 0
      } else {
        entry.gross_other += s.item_price ?? 0
        entry.net_other += s.price_net ?? 0
        entry.tax_other += s.tax_amount ?? 0
      }
    }

    const headers = [
      'Monat', 'Automat', 'Automaten-ID', 'Anzahl Verkäufe',
      'Brutto Gesamt',
      'Brutto 19%', 'Netto 19%', 'MwSt. 19%',
      'Brutto 7%', 'Netto 7%', 'MwSt. 7%',
      'Brutto Sonstige', 'Netto Sonstige', 'MwSt. Sonstige',
      'Bar', 'Karte/Bargeldlos',
    ]

    const sorted = [...map.values()].sort((a, b) =>
      a.month.localeCompare(b.month) || a.machine_name.localeCompare(b.machine_name)
    )

    const rows = sorted.map(e => [
      e.month,
      e.machine_name,
      e.machine_id,
      String(e.count),
      germanNumber(e.gross),
      germanNumber(e.gross_standard), germanNumber(e.net_standard), germanNumber(e.tax_standard),
      germanNumber(e.gross_reduced), germanNumber(e.net_reduced), germanNumber(e.tax_reduced),
      germanNumber(e.gross_other), germanNumber(e.net_other), germanNumber(e.tax_other),
      germanNumber(e.cash), germanNumber(e.cashless),
    ])

    const csv = [
      headers.join(';'),
      ...rows.map(r => r.map(cell => `"${cell}"`).join(';')),
    ].join('\r\n')

    const bom = '\uFEFF'
    const blob = new Blob([bom + csv], { type: 'text/csv;charset=utf-8' })
    const fromStr = dateFrom.value.replace(/-/g, '')
    const toStr = dateTo.value.replace(/-/g, '')
    downloadBlob(blob, `Monatssummary_${fromStr}_${toStr}.csv`)
  }

  function toggleChannel(channel: string) {
    channelFilters.value[channel] = !channelFilters.value[channel]
  }

  return {
    sales,
    filteredSales,
    loading,
    dateFrom,
    dateTo,
    summary,
    vatBreakdown,
    channelFilters,
    availableChannels,
    toggleChannel,
    fetchReportData,
    exportSimpleCsv,
    exportDatev,
    exportMonthlySummary,
  }
}
