import Foundation

@main
struct RelayModelsTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: " + message) }; checks += 1
    }
    static func rejects(_ message: String, _ block: () throws -> Void) {
        do { try block(); fatalError("FAIL: expected rejection: " + message) } catch { checks += 1 }
    }
    static func configuration() -> RelayConfiguration {
        RelayConfiguration(connectionID: "11111111-1111-4111-8111-111111111111", mode: .api,
            displayName: "测试用量来源", usageURL: "https://usage.example.invalid/summary?days=30", periodLabel: "最近30天", mapping: RelayMapping())
    }
    static func main() throws {
        var config = configuration()
        let complete = Data(#"{"entries":[{"name":"示例A","calls":3,"inputTokens":120,"outputTokens":30,"amountUSD":2.5},{"name":"示例B","calls":0,"totalTokens":0,"amountUSD":0}]}"#.utf8)
        let entries = try RelayRules.parseAPI(complete, configuration: config)
        check(entries[0].totalTokens == 150, "derive only explicit input+output")
        check(entries[1].totalTokens == 0 && entries[1].calls == 0, "real zero is retained")
        check(entries[0].sharePercent == 100 && entries[1].sharePercent == 0, "positive-total cost shares")
        let partial = try RelayRules.parseAPI(Data(#"{"entries":[{"name":"部分数据","inputTokens":75,"amountUSD":null}]}"#.utf8), configuration: config)
        check(partial[0].inputTokens == 75 && partial[0].totalTokens == nil, "partial input is not invented total")
        check(partial[0].calls == nil && partial[0].amountUSD == nil, "missing stays unknown")
        let direct = try RelayRules.parseAPI(Data(#"{"entries":[{"name":"直接总数","inputTokens":4,"outputTokens":5,"totalTokens":12}]}"#.utf8), configuration: config)
        check(direct[0].totalTokens == 12, "explicit total remains authoritative")
        let zeroMoney = try RelayRules.parseAPI(Data(#"{"entries":[{"amountUSD":0}]}"#.utf8), configuration: config)
        check(zeroMoney[0].sharePercent == nil, "zero-total share is undefined")
        let oversizedAmount = try RelayRules.amount(NSNumber(value: 1_000_000_000_001.0))
        check(oversizedAmount == nil, "oversized amount is unknown")
        for raw in [#"true"#, #""123""#, #"-1"#, #"1.5"#, #"9007199254740990.5"#, #"9007199254740992"#] {
            rejects("invalid token " + raw) { _ = try RelayRules.parseAPI(Data(("{\"entries\":[{\"totalTokens\":" + raw + "}]}").utf8), configuration: config) }
        }
        let safe = try RelayRules.parseAPI(Data(#"{"entries":[{"totalTokens":9007199254740991}]}"#.utf8), configuration: config)
        check(safe[0].totalTokens == RelayRules.safeInteger, "largest safe integer remains exact")
        rejects("derived overflow") { _ = try RelayRules.total(direct: nil, input: RelayRules.safeInteger, output: 1) }
        check(RelayRules.sum([5, nil]) == nil && RelayRules.sum([0, 0]) == 0, "aggregate requires all contributors")
        config.mapping = RelayMapping(entriesPath: "data.0.items", name: "label", calls: "", inputTokens: "usage.input", outputTokens: "usage.output", totalTokens: "", amountUSD: "cost")
        let nested = try RelayRules.parseAPI(Data(#"{"data":[{"items":[{"label":"嵌套","usage":{"input":7,"output":8},"cost":1.25}]}]}"#.utf8), configuration: config)
        check(nested[0].totalTokens == 15 && nested[0].calls == nil, "nested paths and omitted mappings")
        config.mapping.entriesPath = ""
        rejects("root must be array") { _ = try RelayRules.parseAPI(Data("{}".utf8), configuration: config) }
        config = configuration()
        config.mapping.calls = "counts..calls"
        rejects("malformed dot path") { _ = try RelayRules.validate(config) }
        check(!RelayRules.validPath("calls\n") && RelayRules.validPath("data.0.total_tokens"), "control chars rejected")
        config = configuration()
        for url in ["http://usage.example.invalid/summary", "https://user:secret@usage.example.invalid/summary", "https://usage.example.invalid/summary#x", "https://usage.example.invalid/summary?api_key=example"] {
            rejects("unsafe configured URL") { _ = try RelayRules.validateURL(url, mode: .api) }
        }
        rejects("web credentials in URL") { _ = try RelayRules.validateURL("https://usage.example.invalid/usage?token=example", mode: .web) }
        let validatedURL = try RelayRules.validate(config)
        check(validatedURL.scheme == "https", "benign period query accepted")
        let a = URL(string: "https://usage.example.invalid/a")!, b = URL(string: "https://usage.example.invalid:443/b")!
        check(RelayRules.sameOrigin(a,b), "same origin allows path change")
        check(!RelayRules.sameOrigin(a,URL(string:"https://other.example.invalid/a")!), "cross-origin denied")
        check(!RelayRules.sameOrigin(a,URL(string:"http://usage.example.invalid/a")!), "downgrade denied")
        let page = URL(string:"https://usage.example.invalid/usage?a=1&a=2")!
        check(!RelayRules.exactPage(URL(string:"https://usage.example.invalid/usage?a=2&a=1"), configured:page), "query ordering is strict")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = RelaySnapshot(connectionID:config.connectionID,periodLabel:config.periodLabel,capturedAt:now,sourceLabel:"ignored cached label",status:"live",entries:entries)
        let restored = RelayRules.cached(snapshot,for:config,now:now)
        check(restored?.status == "stale" && restored?.capturedAt == now && restored?.sourceLabel == config.sourceLabel, "cached data retains capture time and configured source")
        snapshot.connectionID = "22222222-2222-4222-8222-222222222222"
        check(RelayRules.cached(snapshot,for:config,now:now) == nil, "changed connection never reuses cache")
        snapshot.connectionID = config.connectionID; snapshot.capturedAt = now.addingTimeInterval(120)
        check(RelayRules.cached(snapshot,for:config,now:now) == nil, "future cache rejected")
        snapshot.capturedAt = now; snapshot.entries = []
        check(snapshot.totalTokens == 0 && snapshot.totalCalls == 0 && snapshot.totalUSD == 0, "confirmed live empty set means zero")
        snapshot.status = "stale"
        check(snapshot.totalTokens == nil && snapshot.totalCalls == nil && snapshot.totalUSD == nil, "stale empty set is unknown")
        let encoder = JSONEncoder(); let encoded = try encoder.encode(partial[0])
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String:Any]
        check(object["totalTokens"] is NSNull && object["calls"] is NSNull, "wire contract retains null fields")
        print("PASS: \(checks) Relay model checks; no accounts, network or Keychain accessed.")
    }
}
