import Foundation
import Supabase

/// CRUD operations for products and product categories.
@MainActor
final class ProductsViewModel: ObservableObject {
    // MARK: - Published State

    @Published var products: [Product] = []
    @Published var categories: [ProductCategory] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var error: String?

    private let client = SupabaseService.shared.client

    /// Products filtered by search text.
    var filteredProducts: [Product] {
        if searchText.isEmpty { return products }
        let query = searchText.lowercased()
        return products.filter {
            ($0.name ?? "").lowercased().contains(query)
        }
    }

    // MARK: - Load

    /// Fetches all products from the `products` table.
    func loadProducts() async {
        isLoading = true
        error = nil

        do {
            products = try await client
                .from("products")
                .select("id, name, image_path, discontinued, sellprice, category")
                .order("name", ascending: true)
                .execute()
                .value
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Fetches all product categories from the `product_category` table.
    func loadCategories() async {
        do {
            categories = try await client
                .from("product_category")
                .select("id, name, company")
                .order("name", ascending: true)
                .execute()
                .value
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads both products and categories in parallel.
    func loadAll() async {
        isLoading = true
        error = nil

        async let productsTask: () = loadProducts()
        async let categoriesTask: () = loadCategories()

        _ = await (productsTask, categoriesTask)

        isLoading = false
    }

    // MARK: - Product CRUD

    /// Creates a new product. Fetches company from organization_members for RLS.
    /// Returns the new product's UUID on success.
    @discardableResult
    func createProduct(name: String, sellprice: Double?, categoryId: UUID?, discontinued: Bool) async -> UUID? {
        isSaving = true
        error = nil

        do {
            let companyId = try await fetchCompanyId()

            var params: [String: AnyJSON] = [
                "name": .string(name),
                "discontinued": .bool(discontinued),
                "company": .string(companyId.uuidString),
            ]
            if let price = sellprice {
                params["sellprice"] = .double(price)
            }
            if let catId = categoryId {
                params["category"] = .string(catId.uuidString)
            }

            struct InsertedProduct: Decodable { let id: UUID }
            let inserted: [InsertedProduct] = try await client
                .from("products")
                .insert(params)
                .select("id")
                .execute()
                .value

            await loadProducts()
            isSaving = false
            return inserted.first?.id
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
        return nil
    }

    /// Updates an existing product.
    func updateProduct(id: UUID, name: String, sellprice: Double?, categoryId: UUID?, discontinued: Bool) async {
        isSaving = true
        error = nil

        var params: [String: AnyJSON] = [
            "name": .string(name),
            "discontinued": .bool(discontinued),
        ]
        if let price = sellprice {
            params["sellprice"] = .double(price)
        } else {
            params["sellprice"] = .null
        }
        if let catId = categoryId {
            params["category"] = .string(catId.uuidString)
        } else {
            params["category"] = .null
        }

        do {
            try await client
                .from("products")
                .update(params)
                .eq("id", value: id.uuidString)
                .execute()

            await loadProducts()
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    /// Deletes a product. Also removes its image from storage if one exists.
    func deleteProduct(id: UUID) async {
        error = nil

        // Find the product to check for image
        if let product = products.first(where: { $0.id == id }),
           let imagePath = product.imagePath, !imagePath.isEmpty {
            // Remove image from storage
            do {
                try await client.storage
                    .from("product-images")
                    .remove(paths: [imagePath])
            } catch {
                print("[ProductsVM] Failed to remove image: \(error)")
            }
        }

        do {
            try await client
                .from("products")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()

            products.removeAll { $0.id == id }
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Category CRUD

    /// Creates a new product category. Fetches company from organization_members for RLS.
    func createCategory(name: String) async {
        isSaving = true
        error = nil

        do {
            let companyId = try await fetchCompanyId()

            let params: [String: AnyJSON] = [
                "name": .string(name),
                "company": .string(companyId.uuidString),
            ]

            try await client
                .from("product_category")
                .insert(params)
                .execute()

            await loadCategories()
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    /// Updates a category's name.
    func updateCategory(id: UUID, name: String) async {
        isSaving = true
        error = nil

        do {
            try await client
                .from("product_category")
                .update(["name": name])
                .eq("id", value: id.uuidString)
                .execute()

            await loadCategories()
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    /// Deletes a category.
    func deleteCategory(id: UUID) async {
        error = nil

        do {
            try await client
                .from("product_category")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()

            categories.removeAll { $0.id == id }
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Image Management

    /// Uploads a product image to the `product-images` storage bucket and updates the product's image_path.
    func uploadProductImage(productId: UUID, imageData: Data, fileExtension: String = "jpg") async {
        isSaving = true
        error = nil

        let path = "\(productId.uuidString).\(fileExtension)"

        do {
            // Upload to storage (upsert = overwrite if exists)
            try await client.storage
                .from("product-images")
                .upload(
                    path: path,
                    file: imageData,
                    options: FileOptions(contentType: "image/jpeg", upsert: true)
                )

            // Update product's image_path
            try await client
                .from("products")
                .update(["image_path": path])
                .eq("id", value: productId.uuidString)
                .execute()

            await loadProducts()
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    /// Removes a product image from storage and nulls the image_path.
    func deleteProductImage(productId: UUID, imagePath: String) async {
        error = nil

        do {
            try await client.storage
                .from("product-images")
                .remove(paths: [imagePath])

            let params: [String: AnyJSON] = ["image_path": .null]
            try await client
                .from("products")
                .update(params)
                .eq("id", value: productId.uuidString)
                .execute()

            await loadProducts()
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Image Search

    /// A suggested image from the search-product-images edge function.
    struct SuggestedImage: Identifiable, Equatable {
        let id = UUID()
        let thumbnail: String
        let image: String
        let title: String
    }

    /// Searches DuckDuckGo for product images via the edge function.
    func searchImages(query: String) async -> [SuggestedImage] {
        guard query.count >= 2 else { return [] }

        do {
            struct SearchResponse: Decodable {
                let images: [ImageResult]
                struct ImageResult: Decodable {
                    let thumbnail: String
                    let image: String
                    let title: String
                }
            }

            let response: SearchResponse = try await client.functions.invoke(
                "search-product-images",
                options: .init(body: ["query": query])
            )

            return response.images.map {
                SuggestedImage(thumbnail: $0.thumbnail, image: $0.image, title: $0.title)
            }
        } catch {
            print("[ProductsVM] Image search failed: \(error)")
            return []
        }
    }

    /// Downloads an image from a URL and uploads it to the product-images bucket.
    func downloadAndUploadImage(productId: UUID, imageUrl: String) async {
        guard let url = URL(string: imageUrl) else { return }

        isSaving = true
        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            // Detect file extension from content type
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let ext: String
            if contentType.contains("png") {
                ext = "png"
            } else if contentType.contains("webp") {
                ext = "webp"
            } else {
                ext = "jpg"
            }

            await uploadProductImage(productId: productId, imageData: data, fileExtension: ext)
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    // MARK: - Barcode CRUD

    /// Fetches all barcodes for a given product.
    func loadBarcodes(productId: UUID) async -> [ProductBarcode] {
        do {
            let result: [ProductBarcode] = try await client
                .from("product_barcodes")
                .select("id, product_id, barcode, format, company_id")
                .eq("product_id", value: productId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value
            return result
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    /// Adds a barcode for a product. Fetches company_id for RLS.
    func addBarcode(productId: UUID, barcode: String, format: String = "EAN-13") async -> Bool {
        do {
            let companyId = try await fetchCompanyId()

            let params: [String: AnyJSON] = [
                "product_id": .string(productId.uuidString),
                "barcode": .string(barcode),
                "format": .string(format),
                "company_id": .string(companyId.uuidString),
            ]

            try await client
                .from("product_barcodes")
                .insert(params)
                .execute()

            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Deletes a barcode by its ID.
    func deleteBarcode(id: UUID) async {
        do {
            try await client
                .from("product_barcodes")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()
        } catch is CancellationError {
            // Ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Fetches the current user's company_id from organization_members.
    private func fetchCompanyId() async throws -> UUID {
        let userId = try await client.auth.session.user.id

        struct OrgMember: Decodable {
            let companyId: UUID
            enum CodingKeys: String, CodingKey { case companyId = "company_id" }
        }

        let members: [OrgMember] = try await client
            .from("organization_members")
            .select("company_id")
            .eq("user_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let companyId = members.first?.companyId else {
            throw NSError(domain: "ProductsVM", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not determine company"])
        }
        return companyId
    }

    /// Returns the category name for a given category UUID.
    func categoryName(for categoryId: UUID?) -> String? {
        guard let catId = categoryId else { return nil }
        return categories.first(where: { $0.id == catId })?.name
    }

    /// Number of products in a given category.
    func productCount(for categoryId: UUID) -> Int {
        products.filter { $0.category == categoryId }.count
    }
}
