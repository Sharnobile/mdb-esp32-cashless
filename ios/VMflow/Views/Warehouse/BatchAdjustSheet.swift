import SwiftUI

/// Bottom sheet for adjusting a warehouse batch's quantity — positive or negative.
/// Preserves batch_number + expiration_date (operates on batch_id).
struct BatchAdjustSheet: View {
    let batch: WarehouseStockBatch
    let productName: String
    let imagePath: String?
    let onSubmit: (Int, WarehouseViewModel.AdjustReason, String?) async -> Void  // (signedDelta, reason, notes)

    @Environment(\.dismiss) private var dismiss

    enum Direction: String, Hashable { case remove, add }

    @State private var direction: Direction = .remove
    @State private var reason: WarehouseViewModel.AdjustReason = .damage
    @State private var quantityText: String = ""
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @FocusState private var quantityFieldFocused: Bool

    /// Reasons valid for the current direction. First entry is the default when direction flips.
    private var reasonsForDirection: [(value: WarehouseViewModel.AdjustReason, label: String)] {
        switch direction {
        case .remove:
            return [
                (.damage, String(localized: "Damaged")),
                (.expired, String(localized: "Expired")),
                (.correction, String(localized: "Inventory correction")),
            ]
        case .add:
            return [
                (.refillReturn, String(localized: "Refill return")),
                (.correction, String(localized: "Inventory correction")),
            ]
        }
    }

    private var parsedQuantity: Int? {
        evaluateExpression(quantityText)
    }

    /// "2026-06-01" → locale-aware short date (DD/MM/YYYY for fr/nl/de); falls back to raw.
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static func displayDate(_ s: String) -> String {
        guard let d = isoFormatter.date(from: s) else { return s }
        return d.formatted(.dateTime.day().month(.twoDigits).year())
    }

    private var canSubmit: Bool {
        guard let q = parsedQuantity, q > 0, !isSubmitting else { return false }
        if direction == .remove { return q <= batch.quantity }
        return true
    }

    private var submitLabel: String {
        direction == .remove
            ? String(localized: "Remove stock")
            : String(localized: "Add stock")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Batch info (read-only header)
                Section {
                    HStack(spacing: 12) {
                        ProductImage(imagePath: imagePath, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(productName).font(.headline)
                            HStack(spacing: 8) {
                                Text(batch.batchNumber ?? String(localized: "No batch"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let exp = batch.expirationDate {
                                    Text(Self.displayDate(exp)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Text("\(batch.quantity)")
                            .font(.title2.bold().monospacedDigit())
                    }
                }

                // Direction toggle
                Section {
                    Picker("Direction", selection: $direction) {
                        Text("− \(String(localized: "Remove"))").tag(Direction.remove)
                        Text("+ \(String(localized: "Add"))").tag(Direction.add)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: direction) { _, _ in
                        // Always reset to the first valid reason for the new direction.
                        // adjustment_correction is valid in both but we still reset —
                        // consistent with the web UX (see useWarehouse composable).
                        reason = reasonsForDirection.first?.value ?? .correction
                    }
                }

                // Reason
                Section("Reason") {
                    Picker("Reason", selection: $reason) {
                        ForEach(reasonsForDirection, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .pickerStyle(.menu)

                    if direction == .add && reason == .refillReturn {
                        Text(String(localized: "Items returned after a refill took too much"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Quantity (supports expressions: 2*12, 100+50)
                Section {
                    HStack {
                        Text(direction == .remove
                             ? String(localized: "Quantity to remove")
                             : String(localized: "Quantity to add"))
                        Spacer()
                        TextField("e.g. 2*12", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                            .font(.body.monospacedDigit())
                            .focused($quantityFieldFocused)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    if quantityFieldFocused {
                                        calculatorToolbar
                                    }
                                }
                            }

                        if quantityText.contains(where: { "+-*/x×".contains($0) }),
                           let q = parsedQuantity, q > 0 {
                            Text("= \(q)")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.blue)
                        }
                    }
                    if direction == .remove,
                       let q = parsedQuantity,
                       q > batch.quantity {
                        Text(String(localized: "Only \(batch.quantity) available"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                // Notes
                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .onAppear {
                // Auto-focus the quantity field so the user can start typing immediately.
                quantityFieldFocused = true
            }
            .navigationTitle(String(localized: "Adjust stock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(submitLabel).bold()
                        }
                    }
                    .tint(direction == .remove ? .red : .green)
                    .disabled(!canSubmit)
                }
            }
        }
    }

    // MARK: - Calculator Toolbar (matches WithdrawalSheet pattern)

    @ViewBuilder
    private var calculatorToolbar: some View {
        HStack(spacing: 8) {
            ForEach(["×", "+", "-", "/"], id: \.self) { op in
                Button {
                    quantityText += op == "×" ? "*" : op
                } label: {
                    Text(op)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(width: 44, height: 36)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                if let result = evaluateExpression(quantityText), result > 0 {
                    quantityText = String(result)
                }
                quantityFieldFocused = false
            } label: {
                Text("=")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 36)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private func submit() async {
        guard let q = parsedQuantity, q > 0 else { return }
        isSubmitting = true
        let signed = direction == .remove ? -q : q
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        await onSubmit(signed, reason, trimmedNotes.isEmpty ? nil : trimmedNotes)
        isSubmitting = false
        dismiss()
    }

    /// Evaluates expressions like "2*12", "100+50". Mirrors `evaluateExpression`
    /// from `WarehouseView.swift` — duplicated intentionally to keep the sheet
    /// self-contained. If a third caller shows up, extract to a shared helper.
    private func evaluateExpression(_ text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        if let num = Int(cleaned) { return num }
        let allowed = CharacterSet(charactersIn: "0123456789+-*/.")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let lastChar = cleaned.last, lastChar.isNumber else { return nil }
        let expression = NSExpression(format: cleaned)
        if let result = expression.expressionValue(with: nil, context: nil) as? NSNumber {
            return result.intValue > 0 ? result.intValue : nil
        }
        return nil
    }
}
