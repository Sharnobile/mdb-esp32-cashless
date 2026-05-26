import SwiftUI

/// Loads product images from Supabase storage with a `.task(id:)`-based loader.
/// Avoids the well-known `AsyncImage` + `LazyVStack` regression where lazy-stack
/// view recycling during initial layout can leave AsyncImage stuck in its empty
/// phase (request cancelled, replacement never fires).
struct ProductImage: View {
    let imagePath: String?
    var size: CGFloat = 44
    /// Optional explicit width. Defaults to `size`. Use when the surrounding
    /// cell is non-square (e.g. the machine-layout grid uses a taller cell to
    /// give product images more vertical room).
    var width: CGFloat? = nil
    /// Optional explicit height. Defaults to `size`.
    var height: CGFloat? = nil

    @State private var image: UIImage?
    @State private var isLoading = false

    private var effectiveWidth: CGFloat { width ?? size }
    private var effectiveHeight: CGFloat { height ?? size }

    private var imageURL: URL? {
        guard let path = imagePath, !path.isEmpty else { return nil }
        let baseURL = SupabaseService.shared.supabaseURL.absoluteString
        return URL(string: "\(baseURL)/storage/v1/object/public/product-images/\(path)")
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: effectiveWidth, height: effectiveHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isLoading {
                ProgressView()
                    .frame(width: effectiveWidth, height: effectiveHeight)
            } else {
                placeholder
            }
        }
        .task(id: imageURL) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let url = imageURL else {
            image = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, let img = UIImage(data: data) else { return }
            image = img
        } catch {
            // Silent fail — placeholder remains visible.
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.systemGray5))
            .frame(width: effectiveWidth, height: effectiveHeight)
            .overlay {
                Image(systemName: "cube.box")
                    .foregroundStyle(.secondary)
                    .font(.system(size: min(effectiveWidth, effectiveHeight) * 0.4))
            }
    }
}

#Preview {
    HStack(spacing: 16) {
        ProductImage(imagePath: nil, size: 60)
        ProductImage(imagePath: "test.jpg", size: 60)
    }
}
