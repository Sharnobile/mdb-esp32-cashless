import Foundation

enum PriceBasis: String { case net, gross }

enum DealVerdict: String { case noEk, implausible, goodBest, good, similar, worse }

struct DealComparison {
    let verdict: DealVerdict
    let deltaPct: Double?   // vs newest (üblicher) gross; negative = cheaper
}

/// Pure purchase-price comparison logic. 1:1 port of purchaseComparison.ts —
/// keep both in sync. (TS Vitest suite is the shared parity guard.)
enum PurchaseComparison {
    static func round4(_ n: Double) -> Double { (n * 10000).rounded() / 10000 }

    static func counterpart(_ value: Double, basis: PriceBasis, rate: Double) -> Double {
        basis == .net ? round4(value * (1 + rate)) : round4(value / (1 + rate))
    }

    /// Net-basis margin VK_net − EK_net. Nil if inputs missing or VK_net ≤ 0.
    static func marginNet(sellpriceGross: Double?, ekNet: Double?, rate: Double?) -> (rohertrag: Double, spannePct: Double)? {
        guard let s = sellpriceGross, let ek = ekNet, let r = rate else { return nil }
        let vkNet = s / (1 + r)
        guard vkNet > 0 else { return nil }
        let rohertrag = vkNet - ek
        return (rohertrag, (rohertrag / vkNet) * 100)
    }

    static func classifyDeal(dealGross: Double?, summary: ProductPurchaseSummary?, tolerancePct: Double = 3) -> DealComparison {
        guard let dg = dealGross, let s = summary, s.ekCount > 0,
              let maxG = s.maxGross, let newest = s.newestGross else {
            return DealComparison(verdict: .noEk, deltaPct: nil)
        }
        let deltaPct = ((dg - newest) / newest) * 100
        if dg > maxG { return DealComparison(verdict: .implausible, deltaPct: deltaPct) }
        if let minG = s.minGross, dg <= minG { return DealComparison(verdict: .goodBest, deltaPct: deltaPct) }
        if dg < newest && abs(deltaPct) > tolerancePct { return DealComparison(verdict: .good, deltaPct: deltaPct) }
        if abs(deltaPct) <= tolerancePct { return DealComparison(verdict: .similar, deltaPct: deltaPct) }
        return DealComparison(verdict: .worse, deltaPct: deltaPct)
    }

    /// Margin if the deal replaced the usual EK (green-case display). Nil if not computable.
    static func marginDelta(sellpriceGross: Double?, dealGross: Double, summary: ProductPurchaseSummary) -> (currentPct: Double, dealPct: Double)? {
        guard let s = sellpriceGross, let rate = summary.effectiveTaxRate, let newestNet = summary.newestNet else { return nil }
        let vkNet = s / (1 + rate)
        guard vkNet > 0 else { return nil }
        let dealNet = dealGross / (1 + rate)
        return (((vkNet - newestNet) / vkNet) * 100, ((vkNet - dealNet) / vkNet) * 100)
    }

    /// A deal card is suppressed iff it has matched products and ALL are implausible.
    static func isCardSuppressed(_ verdicts: [DealVerdict]) -> Bool {
        !verdicts.isEmpty && verdicts.allSatisfy { $0 == .implausible }
    }
}
