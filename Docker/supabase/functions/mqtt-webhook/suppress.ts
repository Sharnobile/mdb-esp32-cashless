/** Match window for brownout-duplicate suppression. Tunable. See spec. */
export const SUPPRESS_WINDOW_MS = 30_000;

export interface SuppressCandidate {
  id: string;
  createdAtMs: number;
}

/**
 * Decide whether an incoming sale is a brownout re-report that should be
 * suppressed (auto-dropped) instead of inserted.
 *
 * Returns the matched existing sale's id (to store as matched_sale_id) or
 * null to insert normally.
 *
 * Safety: only `time_uncertain` sales are ever suppressed — a normal sale
 * (synced clock) is always inserted, even if an identical recent sale exists.
 * Among time_uncertain sales, suppress when a same-key candidate (the caller
 * pre-filters by embedded_id/item_number/item_price/channel) falls within
 * ±windowMs of the incoming created_at.
 */
export function decideSuppress(
  incoming: { timeUncertain: boolean; createdAtMs: number },
  candidates: SuppressCandidate[],
  windowMs: number = SUPPRESS_WINDOW_MS,
): string | null {
  if (!incoming.timeUncertain) return null;
  for (const c of candidates) {
    if (Math.abs(c.createdAtMs - incoming.createdAtMs) <= windowMs) return c.id;
  }
  return null;
}
