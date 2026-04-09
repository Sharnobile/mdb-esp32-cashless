import SwiftUI

/// Colored badge indicating machine online/offline status.
struct StatusBadge: View {
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isOnline ? "Online" : "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(isOnline ? .green : .red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isOnline ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusBadge(isOnline: true)
        StatusBadge(isOnline: false)
    }
}
