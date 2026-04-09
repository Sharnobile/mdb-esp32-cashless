import SwiftUI

/// Reusable KPI card with icon, title, main value, and optional subtitle.
struct KPICard: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String
    let subtitle: LocalizedStringKey?
    let color: Color

    init(icon: String, title: LocalizedStringKey, value: String, subtitle: LocalizedStringKey? = nil, color: Color = .blue) {
        self.icon = icon
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Spacer()
            }

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

#Preview {
    HStack {
        KPICard(
            icon: "eurosign.circle.fill",
            title: "Today",
            value: "142.50",
            subtitle: "Yesterday: 128.00",
            color: .blue
        )
        KPICard(
            icon: "cart.fill",
            title: "Sales",
            value: "47",
            subtitle: "+12%",
            color: .green
        )
    }
    .padding()
}
