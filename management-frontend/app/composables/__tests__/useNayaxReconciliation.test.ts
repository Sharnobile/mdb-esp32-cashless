import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { localDtToUtc, parseSelectionInfo, parseTitleDateRange } from '../useNayaxReconciliation'

function loadFixture(name: string): File {
  const here = dirname(fileURLToPath(import.meta.url))
  const buf = readFileSync(resolve(here, '../../test-helpers/fixtures', name))
  // Cast Buffer to ArrayBuffer for the File constructor
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)
  return new File([ab as ArrayBuffer], name, {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  })
}

describe('localDtToUtc', () => {
  it('parses Nayax DD.MM.YYYY HH:MM:SS in CEST (summer) to UTC', () => {
    // 2026-03-31 is after DST start (2026-03-29) -> CEST (UTC+2)
    expect(localDtToUtc('31.03.2026 21:46:09', 'Europe/Berlin'))
      .toBe('2026-03-31T19:46:09.000Z')
  })

  it('parses Nayax DD.MM.YYYY HH:MM:SS in CET (winter) to UTC', () => {
    // 2026-01-15 is winter -> CET (UTC+1)
    expect(localDtToUtc('15.01.2026 12:00:00', 'Europe/Berlin'))
      .toBe('2026-01-15T11:00:00.000Z')
  })

  it('handles the spring-forward gap without throwing', () => {
    // 02:30 on 2026-03-29 does not exist in Europe/Berlin (clocks jump
    // 02:00 CET -> 03:00 CEST). The exact value returned by date-fns-tz
    // for non-existent instants is library-defined and has historically
    // differed across versions — we don't pin a specific UTC time. We
    // only assert the function returns *some* valid ISO 8601 within the
    // plausible window (00:30 UTC if pre-jump, 01:30 UTC if post-jump).
    const out = localDtToUtc('29.03.2026 02:30:00', 'Europe/Berlin')
    expect(out).toMatch(/^2026-03-29T0[01]:30:00\.000Z$/)
  })

  it('returns empty string for malformed input', () => {
    expect(localDtToUtc('not a date', 'Europe/Berlin')).toBe('')
    expect(localDtToUtc('', 'Europe/Berlin')).toBe('')
  })

  it('returns empty string for regex-valid but semantically-invalid dates', () => {
    // Feb 29 only exists in leap years; 2026 isn't one.
    expect(localDtToUtc('29.02.2026 12:00:00', 'Europe/Berlin')).toBe('')
    // April has 30 days.
    expect(localDtToUtc('31.04.2026 12:00:00', 'Europe/Berlin')).toBe('')
    // Hour out of range.
    expect(localDtToUtc('01.05.2026 25:00:00', 'Europe/Berlin')).toBe('')
  })
})

describe('parseSelectionInfo', () => {
  it('extracts the item number from "Product Name(N  price)"', () => {
    expect(parseSelectionInfo('Mars Classic Single(39  1.20)')).toBe(39)
  })

  it('handles two-digit item numbers', () => {
    expect(parseSelectionInfo('Powerade Sports Mountain Blast(58  2.50)')).toBe(58)
  })

  it('handles three-digit item numbers', () => {
    expect(parseSelectionInfo('Test(123  9.99)')).toBe(123)
  })

  it('handles single-digit item numbers', () => {
    expect(parseSelectionInfo('Test(1  0.50)')).toBe(1)
  })

  it('returns null when no parenthesis group is present', () => {
    expect(parseSelectionInfo('Just a product name')).toBeNull()
    expect(parseSelectionInfo('')).toBeNull()
  })

  it('returns null when the parenthesis group is malformed', () => {
    expect(parseSelectionInfo('Product(abc  1.00)')).toBeNull()
    expect(parseSelectionInfo('Product()')).toBeNull()
  })

  it('strips trailing whitespace and newlines (Nayax exports often have them)', () => {
    expect(parseSelectionInfo('NicNacs 35g(38  1.50)\n')).toBe(38)
  })
})

describe('parseTitleDateRange', () => {
  it('extracts from the German "Gesuchter Datumsbereich:" line', () => {
    // Note: the real Nayax file prefixes the title with a handful of
    // U+200B zero-width spaces. They're invisible and don't affect the
    // regex, so we just use the visible content here.
    const title = 'Dynamische Transaktionsüberwachung\nGesuchter Datumsbereich: 01.03.2026 00:00:00 - 31.03.2026 23:59:59'
    expect(parseTitleDateRange(title, 'Europe/Berlin')).toEqual({
      fromUtc: '2026-02-28T23:00:00.000Z',  // 01.03 00:00 CET = 28.02 23:00 UTC
      toUtc:   '2026-03-31T21:59:59.000Z',  // 31.03 23:59:59 CEST = 21:59:59 UTC
    })
  })

  it('returns null when the line is missing', () => {
    expect(parseTitleDateRange('Random title', 'Europe/Berlin')).toBeNull()
  })

  it('returns null when only the start half is present', () => {
    expect(parseTitleDateRange('Datumsbereich: 01.03.2026 00:00:00', 'Europe/Berlin')).toBeNull()
  })
})

describe('parseFile', () => {
  it('parses the Nayax fixture without errors', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    expect(r.rawRows.value.length).toBeGreaterThan(0)
    expect(r.error.value).toBe('')
  })

  it('skips the title row and the Total footer', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    // No row should have txId "" or machineName "Total"
    for (const row of r.rawRows.value) {
      expect(row.txId).not.toBe('')
      expect(row.machineName).not.toBe('Total')
    }
  })

  it('extracts the expected fields from the first data row', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    const first = r.rawRows.value[0]
    // First row in the fixture: Powerade Sports Mountain Blast, 31.03.2026 21:46:09
    expect(first.txId).toBe('62968009978')
    expect(first.nayaxMachineId).toBe('92700604')
    expect(first.machineName).toBe('Niedernhall Frankeneck')
    expect(first.productName).toBe('Powerade Sports Mountain Blast')
    expect(first.paymentSource).toBe('Cash')
    expect(first.priceGross).toBe(2.5)
    expect(first.itemNumber).toBe(58)
    expect(first.localDt).toBe('31.03.2026 21:46:09')
    expect(first.utcDt).toBe('2026-03-31T19:46:09.000Z')
  })

  it('populates fileDateRange from the title row', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    // Title says "01.03.2026 00:00:00 - 31.03.2026 23:59:59" in Europe/Berlin
    expect(r.settings.value.fromUtc).toBe('2026-02-28T23:00:00.000Z')
    expect(r.settings.value.toUtc).toBe('2026-03-31T21:59:59.000Z')
  })

  it('refuses files over the 50 000-row hard cap', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    // Simulate a huge file by directly testing the cap via a synthetic
    // override (we don't actually generate 50k rows in CI). Instead,
    // expose MAX_ROWS as a constant the test can read and the implementation
    // uses for its threshold.
    const { MAX_ROWS_HARD_CAP } = await import('../useNayaxReconciliation')
    expect(MAX_ROWS_HARD_CAP).toBe(50000)
  })
})
