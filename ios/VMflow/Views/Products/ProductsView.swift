import SwiftUI

/// Two-tab view for managing Products and Categories.
struct ProductsView: View {
    @StateObject private var viewModel = ProductsViewModel()
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                Text("Products").tag(0)
                Text("Categories").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if selectedTab == 0 {
                ProductsTabView(viewModel: viewModel)
            } else {
                CategoriesTabView(viewModel: viewModel)
            }
        }
        .navigationTitle("Products")
        .task {
            await viewModel.loadAll()
        }
        .alert("Error", isPresented: .constant(viewModel.error != nil)) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }
}

// MARK: - Products Tab

struct ProductsTabView: View {
    @ObservedObject var viewModel: ProductsViewModel
    @State private var showAddSheet = false
    @State private var detailProduct: Product?

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.products.isEmpty {
                ProgressView("Loading products...")
                    .frame(maxHeight: .infinity)
            } else if viewModel.filteredProducts.isEmpty {
                emptyState
            } else {
                productList
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search products")
        .refreshable {
            await viewModel.loadAll()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ProductEditSheet(
                product: nil,
                categories: viewModel.categories,
                viewModel: viewModel,
                onSave: { name, price, categoryId, discontinued in
                    return await viewModel.createProduct(name: name, sellprice: price, categoryId: categoryId, discontinued: discontinued)
                },
                onUploadImage: { productId, data in
                    await viewModel.uploadProductImage(productId: productId, imageData: data)
                },
                onDeleteImage: { productId, path in
                    await viewModel.deleteProductImage(productId: productId, imagePath: path)
                },
                onDelete: nil
            )
        }
        // Tapping a row always opens the stats sheet; editing lives behind the
        // pencil in that sheet's toolbar. It edits through its own view model,
        // so refresh the list on dismiss to pick up renames/deletions.
        .sheet(item: $detailProduct, onDismiss: {
            Task { await viewModel.loadAll() }
        }) { product in
            ProductDetailSheet(
                productId: product.id,
                fallbackName: product.name ?? "",
                fallbackImagePath: product.imagePath,
                fallbackSellprice: product.sellprice
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "cube.box")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Products")
                .font(.title3.bold())
            Text("Add your first product to get started.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddSheet = true
            } label: {
                Label("Add Product", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var productList: some View {
        List {
            ForEach(viewModel.filteredProducts) { product in
                ProductRow(
                    product: product,
                    categoryName: viewModel.categoryName(for: product.category)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    detailProduct = product
                }
            }
            .onDelete { indexSet in
                Task {
                    for index in indexSet {
                        let product = viewModel.filteredProducts[index]
                        await viewModel.deleteProduct(id: product.id)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Product Row

struct ProductRow: View {
    let product: Product
    let categoryName: String?

    var body: some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: product.imagePath, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(product.name ?? "Unnamed")
                        .font(.body)
                        .lineLimit(1)

                    if product.discontinued == true {
                        Image(systemName: "archivebox.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let catName = categoryName {
                    Text(catName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let price = product.sellprice {
                Text(String(format: "%.2f \u{20AC}", price))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Categories Tab

struct CategoriesTabView: View {
    @ObservedObject var viewModel: ProductsViewModel
    @State private var showAddAlert = false
    @State private var newCategoryName = ""
    @State private var editingCategory: ProductCategory?
    @State private var editCategoryName = ""

    var body: some View {
        Group {
            if viewModel.categories.isEmpty && !viewModel.isLoading {
                categoriesEmptyState
            } else {
                categoryList
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newCategoryName = ""
                    showAddAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New Category", isPresented: $showAddAlert) {
            TextField("Category name", text: $newCategoryName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                guard !newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                Task {
                    await viewModel.createCategory(name: newCategoryName.trimmingCharacters(in: .whitespaces))
                }
            }
        } message: {
            Text("Enter a name for the new category.")
        }
        .alert("Edit Category", isPresented: .init(
            get: { editingCategory != nil },
            set: { if !$0 { editingCategory = nil } }
        )) {
            TextField("Category name", text: $editCategoryName)
            Button("Cancel", role: .cancel) { editingCategory = nil }
            Button("Save") {
                guard let cat = editingCategory,
                      !editCategoryName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                Task {
                    await viewModel.updateCategory(id: cat.id, name: editCategoryName.trimmingCharacters(in: .whitespaces))
                    editingCategory = nil
                }
            }
        } message: {
            Text("Update the category name.")
        }
    }

    private var categoriesEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Categories")
                .font(.title3.bold())
            Text("Categories help you organize your products.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                newCategoryName = ""
                showAddAlert = true
            } label: {
                Label("Add Category", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private var categoryList: some View {
        List {
            ForEach(viewModel.categories) { category in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.body)
                        Text("\(viewModel.productCount(for: category.id)) products")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    editCategoryName = category.name
                    editingCategory = category
                }
            }
            .onDelete { indexSet in
                Task {
                    for index in indexSet {
                        let category = viewModel.categories[index]
                        let count = viewModel.productCount(for: category.id)
                        if count > 0 {
                            viewModel.error = "\(category.name) has \(count) product(s). Remove products from this category first."
                        } else {
                            await viewModel.deleteCategory(id: category.id)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        ProductsView()
    }
}
