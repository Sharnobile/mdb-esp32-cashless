import Foundation
import Network

/// Triggers the iOS Local Network permission dialog by performing a brief Bonjour browse.
/// Without this, iOS never shows the prompt and silently blocks LAN connections.
final class LocalNetworkPermission: @unchecked Sendable {
    static let shared = LocalNetworkPermission()

    private var browser: NWBrowser?

    /// Call once at app launch (Debug builds only).
    /// Triggers the "allow local network access" dialog on first run.
    func trigger() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready, .cancelled:
                // Permission dialog has been shown (or was already granted).
                // Stop browsing after a short delay.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.browser?.cancel()
                    self?.browser = nil
                }
            case .failed:
                self?.browser?.cancel()
                self?.browser = nil
            default:
                break
            }
        }

        browser.start(queue: .main)
    }
}
