#if DEBUG
import Foundation
import os.log

/// Intercepts every HTTP request the Supabase client issues when the app is
/// launched with `-UITestFixtures` and answers from bundled JSON/PNG fixtures
/// in `Fixtures/` instead of a real network. Wrapped entirely in `#if DEBUG`
/// so none of this reaches the App Store binary (also enforced belt-and-
/// braces by `EXCLUDED_SOURCE_FILE_NAMES = Fixtures*` in Release.xcconfig,
/// which keeps the JSON/PNGs themselves out of the Release bundle).
///
/// See `docs/superpowers/plans/2026-07-17-ios-screenshot-automation.md` and
/// `docs/superpowers/specs/2026-07-15-ios-app-store-release-design.md` §8.
///
/// Routing order (first match wins):
///   1. Exact "METHOD path" overrides — auth token/user, `get-my-organization`.
///   2. `GET /rest/v1/<table>` → bundled `Fixtures/<table>.json`.
///   3. Any other `GET /rest/v1/*` → `[]` (200) — an unanticipated query
///      renders an empty state instead of spinning forever.
///   4. `POST /rest/v1/rpc/*` → `[]` (200) — RPCs are POSTs; the GET-only
///      table fallback above would otherwise 404 them (e.g.
///      `get_new_deals_count`), and callers of RPCs used purely for KPIs
///      already swallow decode/network errors.
///   5. `GET /storage/v1/object/public/product-images/*` → the bundled PNG
///      matching the requested filename, else `product-placeholder.png`.
///   6. Anything else → 404 + `os_log` the full method+path — the moment-to-
///      moment debugging surface while building out fixtures:
///      `xcrun simctl spawn booted log stream --predicate 'category == "fixtures"'`.
final class FixtureURLProtocol: URLProtocol {

    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "de.kerl-handel.app.debug",
        category: "fixtures"
    )

    // MARK: URLProtocol

    /// Only claims requests aimed at the fixture host — `SupabaseService`
    /// points the client at `https://fixtures.invalid` under the flag, and
    /// this class is also registered globally (`URLProtocol.registerClass`)
    /// so `URLSession.shared` callers (namely `ProductImage.swift`) are
    /// covered too. Scoping to the host keeps any unrelated shared-session
    /// traffic (there shouldn't be any under the flag) from being swallowed.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixtures.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            emit404(path: "<no url>", url: nil)
            return
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        let path = url.path
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let wantsSingleObject = request.value(forHTTPHeaderField: "Accept") == "application/vnd.pgrst.object+json"

        if let response = FixtureRouter.respond(
            method: method,
            path: path,
            queryItems: queryItems,
            wantsSingleObject: wantsSingleObject
        ) {
            emit(response, url: url)
        } else {
            os_log(
                "MISS %{public}@ %{public}@",
                log: Self.log, type: .error,
                method, path
            )
            emit404(path: path, url: url)
        }
    }

    override func stopLoading() {
        // Fixtures resolve synchronously in startLoading(); nothing to cancel.
    }

    // MARK: Emitting responses

    private func emit(_ response: FixtureRouter.Response, url: URL) {
        var headers = response.headers
        if headers["content-type"] == nil {
            headers["content-type"] = "application/json"
        }
        guard let httpResponse = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else { return }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func emit404(path: String, url: URL?) {
        let targetURL = url ?? URL(string: "https://fixtures.invalid/")!
        guard let httpResponse = HTTPURLResponse(
            url: targetURL, statusCode: 404, httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"message\":\"fixture not found: \(path)\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Router

/// Pure routing + fixture-loading logic, kept separate from the
/// `URLProtocol` glue above so it's easy to reason about (and could be unit
/// tested) in isolation. Everything here is synchronous — fixtures are
/// small bundled files, never a real network call.
enum FixtureRouter {

    struct Response {
        let status: Int
        let body: Data
        var headers: [String: String] = [:]
    }

    static func respond(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        wantsSingleObject: Bool
    ) -> Response? {
        // 1. Exact "METHOD path" overrides.
        if let response = exactRoute(method: method, path: path) {
            return response
        }

        // 2, 3, 4: PostgREST (`/rest/v1/...`).
        if path.hasPrefix(restPrefix) {
            let resource = String(path.dropFirst(restPrefix.count))

            if resource.hasPrefix("rpc/") {
                // RPCs are POSTs; the KPI/count RPCs used by these screens
                // (e.g. get_new_deals_count) already swallow decode errors,
                // so an empty array is a safe universal stand-in for "no
                // custom fixture for this RPC".
                return jsonArray([])
            }

            guard method == "GET" else {
                // The fixture engine only serves reads. Writes (insert /
                // update / delete) succeed as a no-op so a stray write
                // triggered while poking around doesn't hard-fail the UI.
                return jsonArray([])
            }

            if let rows = loadTable(resource) {
                let filtered = applyFilters(rows, queryItems: queryItems)
                if wantsSingleObject {
                    guard let first = filtered.first else {
                        return Response(status: 406, body: Data("{}".utf8))
                    }
                    return jsonObject(first)
                }
                return jsonArray(filtered)
            }

            // Table has no bundled fixture — empty result, not a miss log.
            // This is deliberately quiet: an unanticipated table read
            // should degrade to an empty state, not spam the miss log that
            // exists to surface genuinely wrong paths/typos.
            return jsonArray([])
        }

        // 5. Storage — product images.
        if method == "GET", path.hasPrefix(storagePrefix) {
            let filename = String(path.dropFirst(storagePrefix.count))
            return imageResponse(filename: filename)
        }

        return nil
    }

    private static let restPrefix = "/rest/v1/"
    private static let storagePrefix = "/storage/v1/object/public/product-images/"

    // MARK: - Exact routes

    private static func exactRoute(method: String, path: String) -> Response? {
        switch (method, path) {
        case ("POST", "/auth/v1/token"):
            return fixtureFileResponse(named: "auth_token")
        case ("GET", "/auth/v1/user"):
            return fixtureFileResponse(named: "auth_user")
        case ("GET", "/functions/v1/get-my-organization"),
             ("POST", "/functions/v1/get-my-organization"):
            // AuthService calls this with `options: .init(method: .get)`,
            // but the CLAUDE.md edge-function table and this plan's task
            // description both describe it as POST — accept either so a
            // future call-site change (or a misremembered method) can't
            // turn into a silent 404 miss.
            return fixtureFileResponse(named: "organization")
        default:
            return nil
        }
    }

    private static func fixtureFileResponse(named name: String) -> Response? {
        guard let data = loadFixtureData(named: name, extension: "json") else { return nil }
        return jsonData(substituteNow(data))
    }

    // MARK: - Table loading

    private static func loadTable(_ name: String) -> [[String: Any]]? {
        guard let data = loadFixtureData(named: name, extension: "json") else { return nil }
        let substituted = substituteNow(data)
        return (try? JSONSerialization.jsonObject(with: substituted)) as? [[String: Any]]
    }

    private static func loadFixtureData(named name: String, extension ext: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    // MARK: - Now-relative timestamps

    private static let nowTokenRegex = try? NSRegularExpression(pattern: "__NOW(?:-(\\d+)([HD]))?__")

    /// Replaces `__NOW__` / `__NOW-2H__` / `__NOW-1D__`-style tokens with an
    /// ISO8601 timestamp computed at request time.
    ///
    /// Fixture JSON is authored with these tokens instead of absolute dates
    /// because `DashboardViewModel` buckets sales client-side against
    /// `Date()` (today / yesterday / this-week / this-month, and the 30-day
    /// chart) — a fixture committed with an absolute past date renders
    /// correctly the day it's written and drifts to €0.00 KPIs and an empty
    /// chart the very next day.
    private static func substituteNow(_ data: Data) -> Data {
        guard let regex = nowTokenRegex,
              var text = String(data: data, encoding: .utf8)
        else { return data }

        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return data }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()

        // Replace back-to-front so earlier match ranges stay valid as the
        // string mutates.
        for match in matches.reversed() {
            var offsetSeconds: TimeInterval = 0
            if match.range(at: 1).location != NSNotFound,
               let amountRange = Range(match.range(at: 1), in: text),
               let unitRange = Range(match.range(at: 2), in: text) {
                let amount = Double(text[amountRange]) ?? 0
                offsetSeconds = text[unitRange] == "D" ? amount * 86400 : amount * 3600
            }
            let timestamp = formatter.string(from: now.addingTimeInterval(-offsetSeconds))
            if let matchRange = Range(match.range, in: text) {
                text.replaceSubrange(matchRange, with: timestamp)
            }
        }
        return Data(text.utf8)
    }

    // MARK: - Query filters

    /// Minimal PostgREST filter emulation covering what these five screens
    /// actually send: `eq.`, `in.(...)`, and the `or=(...)` shorthand (used
    /// by the discontinued-products query). Range/date operators (`gt`,
    /// `gte`, `lte`) are accepted syntactically but not applied — fixture
    /// rows are curated to already satisfy them (stock batches are all
    /// `quantity > 0`; every fixture sale falls inside any 30-day window a
    /// screen queries), so a no-op there is simpler and just as correct as
    /// implementing full range comparison.
    private static func applyFilters(_ rows: [[String: Any]], queryItems: [URLQueryItem]) -> [[String: Any]] {
        let ignoredParams: Set<String> = ["select", "order", "limit", "offset", "columns"]
        var result = rows
        for item in queryItems {
            guard !ignoredParams.contains(item.name), let value = item.value else { continue }
            if item.name == "or" {
                let conditions = orConditions(value)
                result = result.filter { row in conditions.contains { matchesCondition(row: row, condition: $0) } }
            } else {
                result = result.filter { matches(row: $0, column: item.name, opValue: value) }
            }
        }
        return result
    }

    private static func orConditions(_ value: String) -> [String] {
        var trimmed = value
        if trimmed.hasPrefix("(") { trimmed.removeFirst() }
        if trimmed.hasSuffix(")") { trimmed.removeLast() }
        return trimmed.split(separator: ",").map(String.init)
    }

    /// `condition` is PostgREST's `or=` shorthand form: `"column.op.value"`.
    private static func matchesCondition(row: [String: Any], condition: String) -> Bool {
        let parts = condition.split(separator: ".", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return false }
        return matches(row: row, column: parts[0], opValue: "\(parts[1]).\(parts[2])")
    }

    /// `opValue` is `"op.value"`, e.g. `"eq.false"`, `"in.(a,b)"`, `"is.null"`.
    private static func matches(row: [String: Any], column: String, opValue: String) -> Bool {
        guard let dotIndex = opValue.firstIndex(of: ".") else { return true }
        let op = String(opValue[opValue.startIndex..<dotIndex])
        let value = String(opValue[opValue.index(after: dotIndex)...])
        let rowValue = row[column]

        switch op {
        case "eq":
            return stringify(rowValue) == value
        case "neq":
            return stringify(rowValue) != value
        case "is":
            let isNull = rowValue == nil || rowValue is NSNull
            return value == "null" ? isNull : !isNull
        case "in":
            var inner = value
            if inner.hasPrefix("(") { inner.removeFirst() }
            if inner.hasSuffix(")") { inner.removeLast() }
            let candidates = inner.split(separator: ",").map(String.init)
            guard let rowString = stringify(rowValue) else { return false }
            return candidates.contains(rowString)
        default:
            // gt / gte / lt / lte / others: no-op passthrough (see doc comment above).
            return true
        }
    }

    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber: return n.stringValue
        case is NSNull, nil: return nil
        case .some(let other): return "\(other)"
        }
    }

    // MARK: - Response builders

    private static func jsonArray(_ rows: [[String: Any]]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
        let range = rows.isEmpty ? "*/0" : "0-\(rows.count - 1)/\(rows.count)"
        return Response(
            status: 200, body: data,
            headers: ["content-type": "application/json", "content-range": range]
        )
    }

    private static func jsonObject(_ row: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: row)) ?? Data("{}".utf8)
        return Response(status: 200, body: data, headers: ["content-type": "application/json"])
    }

    private static func jsonData(_ data: Data) -> Response {
        Response(status: 200, body: data, headers: ["content-type": "application/json"])
    }

    // MARK: - Storage images

    /// Serves the bundled PNG matching `filename` (a product's `image_path`,
    /// e.g. `"cola-zero.png"`), falling back to the generic
    /// `product-placeholder.png` for any path with no dedicated fixture.
    private static func imageResponse(filename: String) -> Response {
        let candidates = [filename, "product-placeholder.png"]
        for candidate in candidates {
            let name = (candidate as NSString).deletingPathExtension
            let ext = (candidate as NSString).pathExtension
            guard !name.isEmpty, !ext.isEmpty else { continue }
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
               let data = try? Data(contentsOf: url) {
                return Response(status: 200, body: data, headers: ["content-type": "image/png"])
            }
        }
        return Response(status: 404, body: Data(), headers: ["content-type": "application/json"])
    }
}
#endif
