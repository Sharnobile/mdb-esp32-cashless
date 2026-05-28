/**
 * Curated list of IANA timezone identifiers for the Settings UI.
 *
 * The `companies.timezone` column accepts any IANA name — this list
 * is purely cosmetic to keep the dropdown short. If the user's
 * browser-detected zone isn't in this list, callers should prepend
 * it dynamically (see SettingsLowStockCard).
 */
export type CuratedTimezone = {
  /** IANA name (e.g. "Europe/Berlin"). Stored as-is in the DB. */
  id: string
  /** Human-readable label for the dropdown. */
  label: string
}

export const CURATED_TIMEZONES: CuratedTimezone[] = [
  // Europe
  { id: 'Europe/Berlin',     label: 'Berlin (CET/CEST)' },
  { id: 'Europe/Vienna',     label: 'Vienna (CET/CEST)' },
  { id: 'Europe/Zurich',     label: 'Zurich (CET/CEST)' },
  { id: 'Europe/Amsterdam',  label: 'Amsterdam (CET/CEST)' },
  { id: 'Europe/Paris',      label: 'Paris (CET/CEST)' },
  { id: 'Europe/London',     label: 'London (GMT/BST)' },
  { id: 'Europe/Madrid',     label: 'Madrid (CET/CEST)' },
  { id: 'Europe/Rome',       label: 'Rome (CET/CEST)' },
  { id: 'Europe/Warsaw',     label: 'Warsaw (CET/CEST)' },
  { id: 'Europe/Stockholm',  label: 'Stockholm (CET/CEST)' },
  { id: 'Europe/Helsinki',   label: 'Helsinki (EET/EEST)' },
  { id: 'Europe/Athens',     label: 'Athens (EET/EEST)' },
  { id: 'Europe/Istanbul',   label: 'Istanbul (TRT)' },

  // Americas
  { id: 'America/New_York',  label: 'New York (EST/EDT)' },
  { id: 'America/Chicago',   label: 'Chicago (CST/CDT)' },
  { id: 'America/Denver',    label: 'Denver (MST/MDT)' },
  { id: 'America/Los_Angeles', label: 'Los Angeles (PST/PDT)' },
  { id: 'America/Toronto',   label: 'Toronto (EST/EDT)' },
  { id: 'America/Mexico_City', label: 'Mexico City (CST/CDT)' },
  { id: 'America/Sao_Paulo', label: 'São Paulo (BRT)' },

  // Asia / Pacific
  { id: 'Asia/Dubai',        label: 'Dubai (GST)' },
  { id: 'Asia/Singapore',    label: 'Singapore (SGT)' },
  { id: 'Asia/Tokyo',        label: 'Tokyo (JST)' },
  { id: 'Asia/Shanghai',     label: 'Shanghai (CST)' },
  { id: 'Asia/Hong_Kong',    label: 'Hong Kong (HKT)' },
  { id: 'Asia/Seoul',        label: 'Seoul (KST)' },
  { id: 'Australia/Sydney',  label: 'Sydney (AEST/AEDT)' },
  { id: 'Pacific/Auckland',  label: 'Auckland (NZST/NZDT)' },

  // UTC anchor
  { id: 'UTC',               label: 'UTC' },
]

/** Browser-detected zone, falling back to Europe/Berlin if Intl is unavailable. */
export function detectBrowserTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Berlin'
  } catch {
    return 'Europe/Berlin'
  }
}
