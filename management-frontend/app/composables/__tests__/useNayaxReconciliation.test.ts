import { describe, it, expect } from 'vitest'
import { localDtToUtc, parseSelectionInfo, parseTitleDateRange } from '../useNayaxReconciliation'

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
