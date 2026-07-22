import SwiftUI

/// A labeled row combining a direct-entry numeric field with a native +/- stepper,
/// so a value can be either typed in one go or nudged with the buttons. Used for
/// tray configuration fields (slot number, capacity, stock, thresholds) where a
/// plain `Stepper` alone required many taps to reach values far from the default.
struct LabeledStepperField: View {
    let label: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...999

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: $value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .frame(width: 56)
                .onChange(of: value) { _, newValue in
                    let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                    if clamped != newValue { value = clamped }
                }
            Stepper(label, value: $value, in: range)
                .labelsHidden()
                .fixedSize()
        }
    }
}
