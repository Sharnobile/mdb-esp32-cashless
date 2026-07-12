import { formatDateTime } from '@/lib/utils'
import {
  activityActionLabel,
  activityChips,
  activitySummary,
} from '@/lib/activityDescriptor'
import type { ActivityEntryLike, TFn } from '@/lib/activityDescriptor'

/**
 * i18n-bound wrapper around the pure `activityDescriptor` helpers. Both the
 * /history page and the dashboard activity feed use this so their labels and
 * chips stay identical.
 */
export function useActivityDescriptor() {
  const { t, locale } = useI18n()
  const tt: TFn = (key, named) => (named ? t(key, named) : t(key))
  const ctx = () => ({ t: tt, formatDateTime: (iso: string) => formatDateTime(iso, locale.value) })

  return {
    actionLabel: (action: string) => activityActionLabel(action, tt),
    metadataChips: (entry: ActivityEntryLike) => activityChips(entry, ctx()),
    activitySummary: (entry: ActivityEntryLike) => activitySummary(entry, ctx()),
  }
}
