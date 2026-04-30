import SwiftUI

/// Loads product images from Supabase storage with a `.task(id:)`-based loader.
/// Avoids the well-known `AsyncImage` + `LazyVStack` regression where lazy-stack
/// view recycling during initial layout can leave AsyncImage stuck in its empty
/// phase (request cancelled, replacement never fires).
struct ProductImage: View {
    let imagePath: String?
    var size: CGFloat = 44

    @State private var image: UIImage?
    @State private var isLoading = false

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
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isLoading {
                ProgressView()
                    .frame(width: size, height: size)
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
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "cube.box")
                    .foregroundStyle(.secondary)
                    .font(.system(size: size * 0.4))
            }
    }
}

#Preview {
    HStack(spacing: 16) {
        ProductImage(imagePath: nil, size: 60)
        ProductImage(imagePath: "test.jpg", size: 60)
    }
}
