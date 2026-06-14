// Pure, framework-free purchase-price comparison logic.
// PORTED 1:1 to ios/VMflow/Utilities/PurchaseComparison.swift — keep in sync.

export type PriceBasis = 'net' | 'gross'

export interface PurchaseSummary {
  product_id: string
  ek_count: number
  newest_net: number | null
  newest_gross: number | null
  newest_supplier: string | null
  newest_on: string | null
  min_gross: number | null
  min_supplier: string | null
  min_on: string | null
  max_gross: number | null
  effective_tax_rate: number | null
}

export type DealVerdict = 'no_ek' | 'implausible' | 'good_best' | 'good' | 'similar' | 'worse'

export interface DealComparison {
  verdict: DealVerdict
  deltaPct: number | null // vs newest (üblicher) gross; negative = cheaper
}

const round4 = (n: number) => Math.round(n * 1e4) / 1e4

/** Counterpart price from one entered value + basis + tax rate. */
export function counterpart(value: number, basis: PriceBasis, rate: number): number {
  return basis === 'net' ? round4(value * (1 + rate)) : round4(value / (1 + rate))
}

/** Net-basis margin VK_net − EK_net. Null if inputs missing or VK_net ≤ 0. */
export function marginNet(
  sellpriceGross: number | null,
  ekNet: number | null,
  rate: number | null,
): { rohertrag: number; spannePct: number } | null {
  if (sellpriceGross == null || ekNet == null || rate == null) return null
  const vkNet = sellpriceGross / (1 + rate)
  if (vkNet <= 0) return null
  const rohertrag = vkNet - ekNet
  return { rohertrag, spannePct: (rohertrag / vkNet) * 100 }
}

/** Classify a deal's gross price against the product's EK summary. */
export function classifyDeal(
  dealGross: number | null,
  summary: PurchaseSummary | null | undefined,
  tolerancePct = 3,
): DealComparison {
  if (
    dealGross == null || !summary || summary.ek_count === 0 ||
    summary.max_gross == null || summary.newest_gross == null
  ) {
    return { verdict: 'no_ek', deltaPct: null }
  }
  const deltaPct = ((dealGross - summary.newest_gross) / summary.newest_gross) * 100
  if (dealGross > summary.max_gross) return { verdict: 'implausible', deltaPct }
  if (summary.min_gross != null && dealGross <= summary.min_gross) return { verdict: 'good_best', deltaPct }
  if (dealGross < summary.newest_gross && Math.abs(deltaPct) > tolerancePct) return { verdict: 'good', deltaPct }
  if (Math.abs(deltaPct) <= tolerancePct) return { verdict: 'similar', deltaPct }
  return { verdict: 'worse', deltaPct }
}

/** Margin if the deal replaced the usual EK (green-case display). Null if not computable. */
export function marginDelta(
  sellpriceGross: number | null,
  dealGross: number,
  summary: PurchaseSummary,
): { currentPct: number; dealPct: number } | null {
  const rate = summary.effective_tax_rate
  if (sellpriceGross == null || rate == null || summary.newest_net == null) return null
  const vkNet = sellpriceGross / (1 + rate)
  if (vkNet <= 0) return null
  const dealNet = dealGross / (1 + rate)
  return {
    currentPct: ((vkNet - summary.newest_net) / vkNet) * 100,
    dealPct: ((vkNet - dealNet) / vkNet) * 100,
  }
}

/** A deal card is suppressed iff it has matched products and ALL are implausible. */
export function isCardSuppressed(verdicts: DealVerdict[]): boolean {
  return verdicts.length > 0 && verdicts.every((v) => v === 'implausible')
}
