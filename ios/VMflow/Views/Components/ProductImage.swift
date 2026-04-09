import SwiftUI

/// AsyncImage wrapper that loads product images from Supabase storage.
/// Shows a placeholder icon when no image is available or while loading.
struct ProductImage: View {
    let imagePath: String?
    var size: CGFloat = 44

    private var imageURL: URL? {
        guard let path = imagePath, !path.isEmpty else { return nil }
        let baseURL = SupabaseService.shared.supabaseURL.absoluteString
        return URL(string: "\(baseURL)/storage/v1/object/public/product-images/\(path)")
    }

    var body: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                case .failure:
                    placeholder
                case .empty:
                    ProgressView()
                        .frame(width: size, height: size)
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
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
