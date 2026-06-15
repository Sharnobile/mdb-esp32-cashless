import SwiftUI

/// Locale-aware logic for a 6-digit best-before mask (day / month / 2-digit year).
///
/// Field order and separators are derived from the active locale, so German
/// renders `TT.MM.JJ` (`15.06.26`) while US English renders `MM/DD/YY`
/// (`06/15/26`). The two-digit year is expanded to `20JJ` (best-before dates are
/// always near-future). All logic is pure with no UI, so `format`/`parseISO`
/// stay independently testable.
struct LocaleDateMask {
    enum Field {
        case day, month, year
    }

    /// The three segments in the order they are shown / typed.
    let order: [Field]
    /// The two separators: between segment 0–1 and segment 1–2.
    let separators: [String]
    private let isGerman: Bool

    init(locale: Locale) {
        // e.g. de -> "dd.MM.yy", en_US -> "MM/dd/yy", en_GB -> "dd/MM/yy"
        let pattern = DateFormatter.dateFormat(fromTemplate: "ddMMyy", options: 0, locale: locale) ?? "dd.MM.yy"

        var order: [Field] = []
        var separators: [String] = []
        var pendingSep = ""
        var lastField: Field? = nil

        for ch in pattern {
            if let field = LocaleDateMask.field(for: ch) {
                if field != lastField {
                    if lastField != nil { separators.append(pendingSep) }
                    order.append(field)
                    lastField = field
                    pendingSep = ""
                }
                // a repeated letter within the same group (e.g. the second "d") is ignored
            } else if lastField != nil {
                pendingSep.append(ch)
            }
        }

        // Defensive fallback if the locale produced something unexpected.
        if order.count == 3 && separators.count == 2 {
            self.order = order
            self.separators = separators
        } else {
            self.order = [.day, .month, .year]
            self.separators = [".", "."]
        }

        self.isGerman = (locale.language.languageCode?.identifier == "de")
    }

    private static func field(for ch: Character) -> Field? {
        switch ch {
        case "d", "D": return .day
        case "M", "L": return .month
        case "y", "Y", "u": return .year
        default: return nil
        }
    }

    /// Inserts separators into a string of up to 6 digits. No trailing separator
    /// is appended until the next segment actually receives a digit, so
    /// `"15"` stays `"15"` and `"150"` becomes `"15.0"`.
    func format(digits rawDigits: String) -> String {
        let d = Array(rawDigits.filter(\.isNumber).prefix(6))
        guard !d.isEmpty else { return "" }
        var result = String(d[0..<min(2, d.count)])
        if d.count > 2 { result += separators[0] + String(d[2..<min(4, d.count)]) }
        if d.count > 4 { result += separators[1] + String(d[4..<min(6, d.count)]) }
        return result
    }

    /// Parses the (possibly formatted) input into a canonical `yyyy-MM-dd`
    /// string, or `nil` when the input is incomplete or not a real calendar date.
    func parseISO(_ text: String) -> String? {
        let d = text.filter(\.isNumber)
        guard d.count == 6 else { return nil }

        let segments = [
            Int(d.prefix(2)) ?? -1,
            Int(d.dropFirst(2).prefix(2)) ?? -1,
            Int(d.dropFirst(4).prefix(2)) ?? -1,
        ]

        var day = 0, month = 0, twoDigitYear = 0
        for (index, field) in order.enumerated() {
            switch field {
            case .day: day = segments[index]
            case .month: month = segments[index]
            case .year: twoDigitYear = segments[index]
            }
        }

        let year = 2000 + twoDigitYear
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        // Round-trip to reject overflow dates like 31.02 (which would roll over).
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }

        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Like ``parseISO(_:)`` but also rejects dates before `today` — a best-before
    /// date entered at goods intake must not already be in the past. `today` is
    /// injectable so the rule stays testable. Today itself is allowed.
    func parseISO(_ text: String, notBefore today: Date) -> String? {
        guard let iso = parseISO(text) else { return nil }
        return iso >= LocaleDateMask.isoString(from: today) ? iso : nil
    }

    /// Civil (local-timezone, Gregorian) `yyyy-MM-dd` for a given instant.
    private static func isoString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Locale-appropriate placeholder, e.g. `TT.MM.JJ` (de) or `MM/DD/YY` (en).
    var placeholder: String {
        func letter(_ field: Field) -> String {
            switch field {
            case .day: return isGerman ? "T" : "D"
            case .month: return "M"
            case .year: return isGerman ? "J" : "Y"
            }
        }
        let segments = order.map { String(repeating: letter($0), count: 2) }
        return segments[0] + separators[0] + segments[1] + separators[1] + segments[2]
    }
}

/// A masked, locale-aware best-before date field. The user types digits only and
/// the separators appear automatically as they go. Empty means "no expiry"; a
/// complete-but-invalid date turns the text red.
struct ExpiryDateField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool

    private var mask: LocaleDateMask { LocaleDateMask(locale: locale) }

    private var isInvalid: Bool {
        let digitCount = text.filter(\.isNumber).count
        // A complete date is invalid if it isn't a real date or is already in the past.
        return digitCount == 6 && mask.parseISO(text, notBefore: Date()) == nil
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(mask.placeholder, text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(isInvalid ? Color.red : Color.primary)
                .focused($focused)
                .frame(maxWidth: 160)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        if focused {
                            Spacer()
                            Button("Done") { focused = false }
                        }
                    }
                }
                .onChange(of: text) { oldValue, newValue in
                    var digits = String(newValue.filter(\.isNumber).prefix(6))
                    let oldDigits = oldValue.filter(\.isNumber)
                    // Backspacing onto a separator should remove the digit before it.
                    if digits.count == oldDigits.count && newValue.count < oldValue.count {
                        digits = String(digits.dropLast())
                    }
                    let formatted = mask.format(digits: digits)
                    if formatted != newValue { text = formatted }
                }
        }
    }
}
