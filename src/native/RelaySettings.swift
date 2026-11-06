import AppKit
import Foundation
import Security

enum RelayStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.aiusagedashboard", isDirectory: true)
    }
    static func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = file(name)
        try encoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)), data.count <= RelayRules.maxBody else { return nil }
        return try? decoder().decode(type, from: data)
    }
    static func clearReadings() { for name in ["relay-snapshot.json", "relay-connection-state.json"] { try? FileManager.default.removeItem(at: file(name)) } }
}
enum RelayKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "io.github.aiusagedashboard") + ".relay.api" }
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }
    static func read(_ id: String) throws -> String? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &item)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = item as? Data else { throw RelayFailure("无法读取已存访问凭据，请在设置中重新填写。") }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ credential: String?, id: String) throws {
        guard let credential, !credential.isEmpty else { return }
        var q = query(id); q[kSecValueData as String] = Data(credential.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw RelayFailure("访问凭据未能保存到钥匙串。") }
    }
    static func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

private final class RelaySettingsDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
final class RelaySettings: NSObject {
    var onSave: ((RelayConfiguration, String?, Bool) throws -> Void)?
    private var window: NSWindow?
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayName = NSTextField(string: "")
    private let usageURL = NSTextField(string: "")
    private let period = NSTextField(string: "最近30天")
    private let credential = NSSecureTextField(string: "")
    private let clearCredential = NSButton(checkboxWithTitle: "清除已保存的访问凭据", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var fields: [String: NSTextField] = [:]
    private var original: RelayConfiguration?
    func show(_ current: RelayConfiguration?) {
        if window == nil { build() }
        original = current
        displayName.stringValue = current?.displayName ?? ""
        usageURL.stringValue = current?.usageURL ?? ""
        period.stringValue = current?.periodLabel ?? "最近30天"
        mode.selectItem(at: current?.mode == .web ? 1 : 0)
        let m = current?.mapping ?? RelayMapping()
        let values = ["entriesPath": m.entriesPath, "name": m.name, "calls": m.calls, "inputTokens": m.inputTokens,
                      "outputTokens": m.outputTokens, "totalTokens": m.totalTokens, "amountUSD": m.amountUSD]
        for (key, field) in fields { field.stringValue = values[key] ?? "" }
        credential.stringValue = ""; clearCredential.state = .off; message.stringValue = ""
        modeChanged()
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func close() { window?.close(); credential.stringValue = "" }
    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "中转站设置"; w.isReleasedWhenClosed = false; w.minSize = NSSize(width: 670, height: 620); w.center()
        let scroll = NSScrollView(frame: w.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let content = RelaySettingsDocument(frame: NSRect(x: 0, y: 0, width: 650, height: 835))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack); scroll.documentView = content; w.contentView?.addSubview(scroll)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        let intro = NSTextField(wrappingLabelWithString: "接入你自己的只读用量接口。默认未配置，不连接任何中转站。API 模式能显示来源提供的 Token；网页模板只兼容既有按 Key 费用/调用统计页，不推算 Token。")
        intro.font = .systemFont(ofSize: 12); stack.addArrangedSubview(intro)
        mode.addItems(withTitles: ["API（JSON，推荐）", "网页统计模板（仅费用 / 调用）"]); mode.target = self; mode.action = #selector(modeChanged)
        row("连接方式", control: mode, stack: stack)
        displayName.placeholderString = "中转站"; row("显示名称", control: displayName, stack: stack)
        usageURL.placeholderString = "https://example.com/api/usage"; row("用量 URL", control: usageURL, stack: stack)
        row("统计周期标签", control: period, stack: stack)
        credential.placeholderString = "Bearer 凭据；留空保留当前站点已存凭据"; row("API 访问凭据", control: credential, stack: stack)
        stack.addArrangedSubview(clearCredential)
        let security = NSTextField(wrappingLabelWithString: "凭据仅保存在本应用钥匙串中，不放入 URL、配置或日志。更换站点后需重新填写。必须填写完整期间的汇总接口，不能将分页日志第一页当作总量。周期标签不改变 API 数据范围，请确认接口本身返回对应期间。")
        security.font = .systemFont(ofSize: 11); security.textColor = .secondaryLabelColor; stack.addArrangedSubview(security)
        let mappingTitle = NSTextField(labelWithString: "API 字段映射（点路径；数字可作为数组索引）"); mappingTitle.font = .systemFont(ofSize: 13, weight: .semibold); stack.addArrangedSubview(mappingTitle)
        for (key, title) in [("entriesPath", "条目数组路径"), ("name", "名称"), ("calls", "调用次数"), ("inputTokens", "输入 Token"), ("outputTokens", "输出 Token"), ("totalTokens", "总 Token"), ("amountUSD", "费用 USD")] {
            let field = NSTextField(string: key == "entriesPath" ? "entries" : key); fields[key] = field; row(title, control: field, stack: stack)
        }
        let hint = NSTextField(wrappingLabelWithString: "条目数组路径留空表示 JSON 根数组；其他字段留空表示未提供。缺失值保持未知。总 Token 仅使用来源总数，或在输入与输出均有效时求和。网页模板要求完整用量 URL、匹配的周期控件和“按 API Key 调用次数”统计卡片。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; stack.addArrangedSubview(hint)
        message.textColor = .systemRed; message.font = .systemFont(ofSize: 12); stack.addArrangedSubview(message)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 12
        let save = NSButton(title: "保存并连接", target: self, action: #selector(saveSettings)); save.bezelStyle = .rounded
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSettings)); cancel.bezelStyle = .rounded
        buttons.addArrangedSubview(save); buttons.addArrangedSubview(cancel); stack.addArrangedSubview(buttons)
        window = w
    }
    private func row(_ title: String, control: NSView, stack: NSStackView) {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false; control.widthAnchor.constraint(equalToConstant: 450).isActive = true
        row.addArrangedSubview(label); row.addArrangedSubview(control); stack.addArrangedSubview(row)
    }
    @objc private func modeChanged() {
        let api = mode.indexOfSelectedItem == 0
        credential.isEnabled = api; clearCredential.isEnabled = api
        fields.values.forEach { $0.isEnabled = api }
    }
    @objc private func cancelSettings() { close() }
    @objc private func saveSettings() {
        let mapping = RelayMapping(entriesPath: fields["entriesPath"]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            name: fields["name"]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), calls: fields["calls"]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            inputTokens: fields["inputTokens"]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), outputTokens: fields["outputTokens"]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            totalTokens: fields["totalTokens"]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), amountUSD: fields["amountUSD"]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        let configuration = RelayConfiguration(connectionID: UUID().uuidString, mode: mode.indexOfSelectedItem == 0 ? .api : .web,
            displayName: displayName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), usageURL: usageURL.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            periodLabel: period.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), mapping: mapping)
        do {
            _ = try RelayRules.validate(configuration)
            let token = credential.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count <= 8192, !token.contains("\r"), !token.contains("\n") else { throw RelayFailure("访问凭据格式无效。") }
            try onSave?(configuration, token.isEmpty ? nil : token, clearCredential.state == .on)
            close()
        } catch { message.stringValue = (error as? RelayFailure)?.message ?? "设置未能保存，请检查输入或钥匙串访问权限。" }
    }
}
