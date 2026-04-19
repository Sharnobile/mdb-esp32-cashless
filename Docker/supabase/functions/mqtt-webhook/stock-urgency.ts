/**
 * Map a tray's current stock and refill threshold to a prefix emoji for
 * sale push notifications. Returns a string that already contains the
 * trailing space ("⚠️ ") so it can be concatenated directly; returns the
 * empty string when no urgency indicator should appear.
 *
 * Thresholds:
 *  - currentStock === 0              → 🚨 (empty, always shown)
 *  - fillWhenBelow === 0             → no further indicator (no threshold)
 *  - currentStock <= fillWhenBelow   → ⚠️ (critical, needs refill)
 *  - currentStock <= 1.5 * threshold → 🟡 (warning zone)
 *  - otherwise                       → '' (normal)
 */
export function stockUrgency(currentStock: number, fillWhenBelow: number): string {
  if (currentStock === 0) return '🚨 '
  if (fillWhenBelow === 0) return ''
  if (currentStock <= fillWhenBelow) return '⚠️ '
  if (currentStock <= fillWhenBelow * 1.5) return '🟡 '
  return ''
}
