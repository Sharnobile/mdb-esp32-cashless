import { formatDateTime } from '@/lib/utils'
import {
  activityActionLabel,
  activityChips,
  activityIcon,
  activityProductRef,
  activitySummary,
} from '@/lib/activityDescriptor'
import type { ActivityEntryLike, TFn } from '@/lib/activityDescriptor'

/**
 * i18n-bound wrapper around the pure `activityDescriptor` helpers. Both the
 * /history page and the dashboard activity feed use this so their labels,
 * icons and chips stay identical.
 *
 * Pass `machineName` (a reactive id → name lookup) so machine chips render the
 * name instead of a raw UUID. The dashboard omits it (its rows already carry
 * machine_name in metadata).
 */
export function useActivityDescriptor(opts?: {
  machineName?: (id: string) => string | undefined
  machineNameByDevice?: (deviceId: string) => string | undefined
}) {
  const { t, locale } = useI18n()
  const tt: TFn = (key, named) => (named ? t(key, named) : t(key))
  const ctx = () => ({
    t: tt,
    formatDateTime: (iso: string) => formatDateTime(iso, locale.value),
    machineName: opts?.machineName,
    machineNameByDevice: opts?.machineNameByDevice,
  })

  return {
    actionLabel: (action: string) => activityActionLabel(action, tt),
    actionIcon: (action: string) => activityIcon(action),
    productRef: (entry: ActivityEntryLike) => activityProductRef(entry),
    metadataChips: (entry: ActivityEntryLike) => activityChips(entry, ctx()),
    activitySummary: (entry: ActivityEntryLike) => activitySummary(entry, ctx()),
  }
}
