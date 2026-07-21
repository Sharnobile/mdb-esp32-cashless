import SwiftUI
import MapKit
import CoreLocation
import CoreImage.CIFilterBuiltins

/// Machine settings: Nayax ID, country, location, and the public status-page
/// link + QR code. Mirrors the web's `MachineSettingsModal.vue`; its map-based
/// address search (Leaflet + Nominatim) is replaced here with MapKit +
/// `CLGeocoder`, since the phone's own GPS is the fast path for placing a
/// machine on-site.
struct MachineSettingsSheet: View {
    @ObservedObject var viewModel: MachineDetailViewModel
    @Environment(\.dismiss) private var dismiss

    /// Same list as the web's `COUNTRY_OPTIONS` (useTaxSettings.ts) — native-
    /// language labels are proper nouns, left untranslated on both platforms.
    private static let countryOptions: [(code: String, label: String)] = [
        ("DE", "Deutschland"), ("AT", "Österreich"), ("CH", "Schweiz"), ("FR", "France"),
        ("IT", "Italia"), ("ES", "España"), ("NL", "Nederland"), ("BE", "Belgique"),
        ("PL", "Polska"), ("CZ", "Česko"), ("PT", "Portugal"), ("LU", "Luxembourg"),
    ]

    @State private var nayaxId: String
    @State private var countryCode: String?
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var addressStreet: String?
    @State private var addressHouseNumber: String?
    @State private var addressPostalCode: String?
    @State private var addressCity: String?
    @State private var formattedAddress: String?
    @State private var publicListing: Bool
    @State private var cameraPosition: MapCameraPosition
    @State private var isSaving = false
    @State private var isLocating = false
    @State private var saveError: String?

    /// Best-effort public frontend origin, remembered once the user confirms
    /// or corrects it — see `defaultPublicOrigin()`.
    @AppStorage("vmflow-public-frontend-origin") private var storedOrigin = ""
    @State private var publicOrigin = ""

    @StateObject private var locationFetcher = OneShotLocationFetcher()

    init(viewModel: MachineDetailViewModel) {
        self.viewModel = viewModel
        let machine = viewModel.machine
        _nayaxId = State(initialValue: machine.nayaxMachineId ?? "")
        _countryCode = State(initialValue: machine.countryCode)
        let coord: CLLocationCoordinate2D? = machine.locationLat.flatMap { lat in
            machine.locationLon.map { lon in CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        }
        _coordinate = State(initialValue: coord)
        _addressStreet = State(initialValue: machine.addressStreet)
        _addressHouseNumber = State(initialValue: machine.addressHouseNumber)
        _addressPostalCode = State(initialValue: machine.addressPostalCode)
        _addressCity = State(initialValue: machine.addressCity)
        _formattedAddress = State(initialValue: machine.formattedAddress)
        _publicListing = State(initialValue: machine.publicListing ?? false)
        let region = MKCoordinateRegion(
            center: coord ?? CLLocationCoordinate2D(latitude: 48.1351, longitude: 11.5820),
            span: MKCoordinateSpan(latitudeDelta: coord == nil ? 20 : 0.01, longitudeDelta: coord == nil ? 20 : 0.01)
        )
        _cameraPosition = State(initialValue: .region(region))
    }

    private var publicUrl: String {
        "\(publicOrigin)/m/\(viewModel.machine.id.uuidString)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Nayax")) {
                    TextField(String(localized: "Nayax Machine ID"), text: $nayaxId)
                        .autocorrectionDisabled()
                }

                Section(String(localized: "Country")) {
                    Picker(String(localized: "Country"), selection: $countryCode) {
                        Text(String(localized: "None")).tag(String?.none)
                        ForEach(Self.countryOptions, id: \.code) { option in
                            Text(option.label).tag(String?.some(option.code))
                        }
                    }
                }

                Section {
                    MapReader { proxy in
                        Map(position: $cameraPosition) {
                            if let coordinate {
                                Marker(viewModel.machine.displayName, coordinate: coordinate)
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { point in
                            guard let tapped = proxy.convert(point, from: .local) else { return }
                            coordinate = tapped
                            Task { await reverseGeocode(tapped) }
                        }
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())

                    if let formattedAddress, !formattedAddress.isEmpty {
                        Text(formattedAddress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        if isLocating {
                            ProgressView()
                        } else {
                            Label(String(localized: "Use My Location"), systemImage: "location.fill")
                        }
                    }
                    .disabled(isLocating)

                    if coordinate != nil {
                        Button(role: .destructive) {
                            coordinate = nil
                            addressStreet = nil
                            addressHouseNumber = nil
                            addressPostalCode = nil
                            addressCity = nil
                            formattedAddress = nil
                        } label: {
                            Text(String(localized: "Clear Location"))
                        }
                    }
                } header: {
                    Text(String(localized: "Location"))
                } footer: {
                    Text(String(localized: "Tap the map to place the machine, or use your current position."))
                }

                Section {
                    Toggle(String(localized: "Public Status Page"), isOn: $publicListing)
                    if publicListing {
                        TextField(String(localized: "Public URL"), text: $publicOrigin)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                        if let qr = qrImage(from: publicUrl) {
                            HStack {
                                Spacer()
                                Image(uiImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 160, height: 160)
                                Spacer()
                            }
                        }
                        Text(publicUrl)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text(String(localized: "Anyone with this link can see this machine's live status, without signing in."))
                }

                if let saveError {
                    Section { Text(saveError).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(String(localized: "Machine Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear {
                publicOrigin = storedOrigin.isEmpty ? defaultPublicOrigin() : storedOrigin
            }
            .onChange(of: publicOrigin) { _, newValue in storedOrigin = newValue }
        }
    }

    private func useCurrentLocation() async {
        isLocating = true
        defer { isLocating = false }
        guard let coord = await locationFetcher.requestLocation() else {
            saveError = String(localized: "Couldn't determine your location.")
            return
        }
        coordinate = coord
        cameraPosition = .region(MKCoordinateRegion(
            center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
        await reverseGeocode(coord)
    }

    /// Best-effort — the pinned coordinate is saved regardless of whether
    /// reverse geocoding succeeds.
    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
        addressStreet = placemark.thoroughfare
        addressHouseNumber = placemark.subThoroughfare
        addressPostalCode = placemark.postalCode
        addressCity = placemark.locality
        if countryCode == nil { countryCode = placemark.isoCountryCode }
        formattedAddress = [placemark.subThoroughfare, placemark.thoroughfare, placemark.postalCode, placemark.locality]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let trimmedNayax = nayaxId.trimmingCharacters(in: .whitespaces)
        let ok = await viewModel.updateSettings(
            locationLat: coordinate?.latitude, locationLon: coordinate?.longitude,
            addressStreet: addressStreet, addressHouseNumber: addressHouseNumber,
            addressPostalCode: addressPostalCode, addressCity: addressCity,
            formattedAddress: formattedAddress,
            countryCode: countryCode, nayaxMachineId: trimmedNayax.isEmpty ? nil : trimmedNayax,
            publicListing: publicListing
        )
        if ok {
            dismiss()
        } else {
            saveError = viewModel.error ?? String(localized: "Failed to save settings.")
        }
    }

    /// Best-effort public frontend URL guess for `/m/{id}`. The API (Kong,
    /// default port 8000) and the Nuxt frontend (default port 3000) are
    /// separate services in this deployment; there is no reliable way to
    /// derive one from the other in general (a production setup may
    /// reverse-proxy them under entirely different hosts). This is only a
    /// starting guess — always editable above, and remembered once corrected.
    private func defaultPublicOrigin() -> String {
        let api = SupabaseService.shared.supabaseURL
        guard var components = URLComponents(url: api, resolvingAgainstBaseURL: false) else {
            return api.absoluteString
        }
        if components.port == 8000 { components.port = 3000 }
        return components.url?.absoluteString ?? api.absoluteString
    }

    private func qrImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// One-shot current-location fetch wrapped as async/await. Not reused as a
/// long-lived tracker — placing a machine only needs a single fix.
@MainActor
private final class OneShotLocationFetcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestLocation() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                continuation.resume(returning: nil)
                self.continuation = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                self.continuation?.resume(returning: nil)
                self.continuation = nil
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.continuation?.resume(returning: locations.first?.coordinate)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
    }
}
