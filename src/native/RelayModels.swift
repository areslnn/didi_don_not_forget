import Foundation
import CoreFoundation

enum RelayMode: String, Codable { case api, web }
struct RelayMapping: Codable, Equatable {
    var entriesPath = "entries"
    var name = "name"
    var calls = "calls"
    var inputTokens = "inputTokens"
    var outputTokens = "outputTokens"
    var totalTokens = "totalTokens"
    var amountUSD = "amountUSD"
}
struct RelayConfiguration: Codable, Equatable {
    var connectionID: String
    var mode: RelayMode
    var displayName: String
    var usageURL: String
    var periodLabel: String
    var mapping: RelayMapping
    var sourceLabel: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "中转站" : displayName }
}
struct RelayEntry: Codable {
    var name: String
    var calls: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var amountUSD: Double?
    var sharePercent: Double?
    enum CodingKeys: String, CodingKey { case name, calls, inputTokens, outputTokens, totalTokens, amountUSD, sharePercent }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(name, forKey: .name)
        try box.encode(calls, forKey: .calls); try box.encode(inputTokens, forKey: .inputTokens)
        try box.encode(outputTokens, forKey: .outputTokens); try box.encode(totalTokens, forKey: .totalTokens)
        try box.encode(amountUSD, forKey: .amountUSD); try box.encode(sharePercent, forKey: .sharePercent)
    }
}
struct RelaySnapshot: Codable {
    var connectionID: String
    var periodLabel: String
    var capturedAt: Date?
    var sourceLabel: String
    var status: String
    var entries: [RelayEntry]
    var hasReadings: Bool { ["live", "stale", "snapshot"].contains(status) && capturedAt != nil && (!entries.isEmpty || status == "live") }
    var totalTokens: Int? { hasReadings ? RelayRules.sum(entries.map(\.totalTokens)) : nil }
    var totalCalls: Int? { hasReadings ? RelayRules.sum(entries.map(\.calls)) : nil }
    var totalUSD: Double? {
        guard hasReadings, entries.allSatisfy({ $0.amountUSD != nil }) else { return nil }
        let result = entries.reduce(0) { $0 + ($1.amountUSD ?? 0) }
        return result.isFinite ? result : nil
    }
}
struct RelayFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
enum RelayRules {
    static let safeInteger = 9_007_199_254_740_991
    static let maxBody = 2 * 1024 * 1024
    static func validate(_ configuration: RelayConfiguration) throws -> URL {
        guard UUID(uuidString: configuration.connectionID) != nil,
              configuration.displayName.count <= 80, configuration.periodLabel.count <= 80,
              !configuration.periodLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.displayName.contains("://"), !configuration.displayName.contains("\n") else {
            throw RelayFailure("显示名称、统计周期或连接标识无效。")
        }
        for path in [configuration.mapping.entriesPath, configuration.mapping.name, configuration.mapping.calls,
                     configuration.mapping.inputTokens, configuration.mapping.outputTokens, configuration.mapping.totalTokens, configuration.mapping.amountUSD] {
            guard validPath(path) else { throw RelayFailure("字段映射须为不超过 256 字的点路径；字段段可用字母、数字、下划线、短横线或数组索引。") }
        }
        return try validateURL(configuration.usageURL, mode: configuration.mode)
    }
    static func validateURL(_ text: String, mode: RelayMode) throws -> URL {
        guard text.count <= 2048, let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw RelayFailure("请输入完整 HTTPS 用量地址，不要包含账号密码或 # 片段。") }
        do {
            for item in components.queryItems ?? [] {
                let key = item.name.lowercased().replacingOccurrences(of: "-", with: "_")
                let sensitive = ["token", "secret", "password", "passwd", "credential", "authorization", "api_key", "apikey"]
                if ["key", "auth", "signature", "sig"].contains(key) || sensitive.contains(where: { key.contains($0) }) ||
                    (item.value ?? "").lowercased().hasPrefix("bearer ") {
                    throw RelayFailure("API 地址的查询参数不能携带凭据，请使用专用凭据输入框。")
                }
            }
        }
        return url
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == "https" && b.scheme?.lowercased() == "https" &&
        a.host?.lowercased() == b.host?.lowercased() && (a.port ?? 443) == (b.port ?? 443)
    }
    static func exactPage(_ actual: URL?, configured: URL) -> Bool {
        guard let actual, sameOrigin(actual, configured), actual.path == configured.path else { return false }
        return actual.user == nil && actual.password == nil && actual.fragment == nil &&
            URLComponents(url: actual, resolvingAgainstBaseURL: false)?.percentEncodedQuery ==
            URLComponents(url: configured, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    }
    static func validPath(_ path: String) -> Bool {
        if path.isEmpty { return true }
        guard path.count <= 256, path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let parts = path.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count <= 24 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 80 && String(part).range(of: "^[\\p{L}_][\\p{L}\\p{N}_-]*$|^[0-9]+$", options: .regularExpression) != nil
        }
    }
    /// Missing/null are unknown. Booleans, strings, fractions and out-of-range values are invalid.
    static func integer(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw RelayFailure("计数必须是 JSON 整数或 null。") }
        let kind = String(cString: n.objCType)
        guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(kind) else { throw RelayFailure("计数必须使用 JSON 整数，不能使用浮点数。") }
        if ["C", "S", "I", "L", "Q"].contains(kind) {
            guard n.uint64Value <= UInt64(safeInteger) else { throw RelayFailure("计数超出非负安全整数范围。") }
            return Int(n.uint64Value)
        }
        guard n.int64Value >= 0, n.int64Value <= Int64(safeInteger) else { throw RelayFailure("计数超出非负安全整数范围。") }
        return Int(n.int64Value)
    }
    static func amount(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else {
            throw RelayFailure("费用必须是非负有限 JSON 数值或 null。")
        }
        return n.doubleValue <= 1_000_000_000_000 ? n.doubleValue : nil
    }
    static func total(direct: Int?, input: Int?, output: Int?) throws -> Int? {
        if let direct { return direct }
        guard let input, let output else { return nil }
        let result = input.addingReportingOverflow(output)
        guard !result.overflow, result.partialValue <= safeInteger else { throw RelayFailure("Token 总数超出安全整数范围。") }
        return result.partialValue
    }
    static func sum(_ values: [Int?]) -> Int? {
        var result = 0
        for value in values {
            guard let value, value >= 0, value <= safeInteger else { return nil }
            let next = result.addingReportingOverflow(value)
            guard !next.overflow, next.partialValue <= safeInteger else { return nil }
            result = next.partialValue
        }
        return result
    }
    static func value(at path: String, in object: Any) -> Any? {
        guard !path.isEmpty else { return nil }
        var current: Any = object
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { return nil }
            if let dict = current as? [String: Any], let next = dict[String(part)] { current = next }
            else if let array = current as? [Any], let index = Int(part), array.indices.contains(index) { current = array[index] }
            else { return nil }
        }
        return current
    }
    static func parseAPI(_ data: Data, configuration: RelayConfiguration) throws -> [RelayEntry] {
        guard data.count <= maxBody else { throw RelayFailure("用量响应超过 2 MiB 限制。") }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw RelayFailure("用量响应不是有效 JSON，请检查地址或重新授权。") }
        let candidate: Any? = configuration.mapping.entriesPath.isEmpty ? root : value(at: configuration.mapping.entriesPath, in: root)
        guard let rows = candidate as? [[String: Any]], rows.count <= 1000 else {
            throw RelayFailure("未找到用量条目数组，请检查 entriesPath 映射。")
        }
        let m = configuration.mapping
        var entries: [RelayEntry] = []
        for (index, row) in rows.enumerated() {
            let rawName = value(at: m.name, in: row)
            if let rawName, !(rawName is NSNull), !(rawName is String) { throw RelayFailure("名称映射必须指向字符串。") }
            let name = (rawName as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (name?.count ?? 0) <= 120 else { throw RelayFailure("条目名称过长。") }
            let input = try integer(value(at: m.inputTokens, in: row)), output = try integer(value(at: m.outputTokens, in: row))
            let direct = try integer(value(at: m.totalTokens, in: row))
            entries.append(RelayEntry(name: name?.isEmpty == false ? name! : "未命名条目 \(index+1)",
                calls: try integer(value(at: m.calls, in: row)), inputTokens: input, outputTokens: output,
                totalTokens: try total(direct: direct, input: input, output: output),
                amountUSD: try amount(value(at: m.amountUSD, in: row)), sharePercent: nil))
        }
        return shares(entries)
    }
    static func shares(_ source: [RelayEntry]) -> [RelayEntry] {
        guard source.allSatisfy({ $0.amountUSD != nil }) else { return source.map { var entry = $0; entry.sharePercent = nil; return entry } }
        let cost = source.reduce(0) { $0 + ($1.amountUSD ?? 0) }
        guard cost.isFinite else { return source.map { var entry = $0; entry.sharePercent = nil; return entry } }
        return source.map { value in var result = value; result.sharePercent = cost > 0 ? 100 * (value.amountUSD ?? 0) / cost : nil; return result }
    }
    static func cached(_ saved: RelaySnapshot, for configuration: RelayConfiguration, now: Date = Date()) -> RelaySnapshot? {
        guard saved.connectionID == configuration.connectionID, saved.periodLabel == configuration.periodLabel,
              ["live", "stale", "snapshot"].contains(saved.status), let date = saved.capturedAt,
              date <= now.addingTimeInterval(60), saved.entries.count <= 1000,
              let entries = try? saved.entries.map(validateEntry) else { return nil }
        var result = saved
        result.entries = shares(entries); result.status = "stale"; result.sourceLabel = configuration.sourceLabel
        return result
    }
    static func validateEntry(_ entry: RelayEntry) throws -> RelayEntry {
        guard entry.name.count <= 120 else { throw RelayFailure("条目名称无效。") }
        for value in [entry.calls, entry.inputTokens, entry.outputTokens, entry.totalTokens] {
            if let value, value < 0 || value > safeInteger { throw RelayFailure("缓存计数无效。") }
        }
        if let value = entry.amountUSD, !value.isFinite || value < 0 { throw RelayFailure("缓存费用无效。") }
        if let value = entry.sharePercent, !value.isFinite || value < 0 || value > 100 { throw RelayFailure("缓存占比无效。") }
        var result = entry
        if let amount = result.amountUSD, amount > 1_000_000_000_000 { result.amountUSD = nil; result.sharePercent = nil }
        result.totalTokens = try total(direct: entry.totalTokens, input: entry.inputTokens, output: entry.outputTokens)
        return result
    }
}
