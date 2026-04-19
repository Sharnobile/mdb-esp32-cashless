import UserNotifications
import os.log

/// Notification Service Extension: intercepts incoming remote notifications
/// with `mutable-content: 1`, downloads any `image` URL from the payload,
/// and attaches it as a `UNNotificationAttachment` so iOS renders it as a
/// thumbnail (lock screen / banner) and large preview (expanded view).
///
/// Every failure path delivers the original text notification unchanged —
/// image loss is never allowed to swallow or delay a notification.
final class NotificationService: UNNotificationServiceExtension {

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "NotificationService",
        category: "push"
    )

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?
    private let deliveryLock = NSLock()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttemptContent = bestAttemptContent else {
            // `mutableCopy` effectively always succeeds on a valid content
            // object, but if it ever doesn't we must still deliver.
            deliverOnce(request.content)
            return
        }

        guard let imageURL = Self.imageURL(from: request.content.userInfo) else {
            // No image in payload (e.g. inbox / low_stock today) — deliver as-is.
            deliverOnce(bestAttemptContent)
            return
        }

        downloadTask = URLSession.shared.downloadTask(with: imageURL) { [weak self] tempURL, response, error in
            guard let self = self,
                  let bestAttemptContent = self.bestAttemptContent else {
                return
            }

            // Deliver no matter what happens below.
            defer { self.deliverOnce(bestAttemptContent) }

            if let error = error {
                os_log(
                    "Image download failed: %{public}@",
                    log: Self.log, type: .info,
                    error.localizedDescription
                )
                return
            }

            guard let tempURL = tempURL,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                os_log(
                    "Image download returned non-success status",
                    log: Self.log, type: .info
                )
                return
            }

            // URLSession gives us a random tempfile without extension; iOS
            // relies on the extension to infer the UTI for attachments, so
            // rename before attaching.
            let fileExtension = Self.fileExtension(for: imageURL)
            let targetURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)

            do {
                try FileManager.default.moveItem(at: tempURL, to: targetURL)
                let attachment = try UNNotificationAttachment(
                    identifier: "image",
                    url: targetURL,
                    options: nil
                )
                bestAttemptContent.attachments = [attachment]
            } catch {
                os_log(
                    "Attachment setup failed: %{public}@",
                    log: Self.log, type: .info,
                    error.localizedDescription
                )
                try? FileManager.default.removeItem(at: targetURL)
            }
        }
        downloadTask?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS gives us ~30 s. On timeout, cancel and deliver whatever we have.
        downloadTask?.cancel()
        if let content = bestAttemptContent {
            deliverOnce(content)
        }
    }

    /// Call `contentHandler` at most once, even under concurrent calls from
    /// the URLSession delegate queue (download completion) and the main
    /// thread (`serviceExtensionTimeWillExpire`). Apple's contract is that
    /// calling the handler more than once is undefined behavior.
    private func deliverOnce(_ content: UNNotificationContent) {
        deliveryLock.lock()
        let handler = contentHandler
        contentHandler = nil
        deliveryLock.unlock()
        handler?(content)
    }

    // MARK: - Pure helpers

    /// Extract a safe HTTP(S) URL from the push `userInfo`. Returns `nil` for
    /// any malformed or non-web URL, including unexpected types.
    static func imageURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo["image"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// Map a remote URL's path extension to one `UNNotificationAttachment`
    /// supports. Unknown / missing extensions fall back to `jpg` which matches
    /// the most common product-image format and lets iOS attempt UTI inference
    /// at attachment time (it will throw if the data is truly not an image,
    /// which we handle in the caller).
    static func fileExtension(for url: URL) -> String {
        let supported: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif"]
        let ext = url.pathExtension.lowercased()
        return supported.contains(ext) ? ext : "jpg"
    }
}
