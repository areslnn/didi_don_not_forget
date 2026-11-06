import AppKit
import Foundation
import Darwin

/// The only executable selection used by the native launchers. An explicit
/// DASHBOARD_PYTHON must identify a Python 3 executable; no shell is involved.
enum PythonRuntime {
    static func executable() throws -> URL {
        let override = ProcessInfo.processInfo.environment["DASHBOARD_PYTHON"]
        let path = (override?.isEmpty == false ? override! : "/usr/bin/python3") as NSString
        let resolved = path.expandingTildeInPath
        guard resolved.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw RuntimeIssue("未找到 Python 3。请安装 Python 3，或设置 DASHBOARD_PYTHON 的绝对路径。")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard !process.isRunning else { process.terminate(); throw RuntimeIssue("Python 3 启动超时，请检查 DASHBOARD_PYTHON。") }
        let version = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0, version.hasPrefix("Python 3.") else {
            throw RuntimeIssue("当前解释器不是可用的 Python 3。")
        }
        return URL(fileURLWithPath: resolved)
    }
}

struct RuntimeIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Opt-in LAN bridge. It owns and stops only the subprocess it created, never
/// a service found on the same port. Pairing material stays in Application Support.
@MainActor
final class SharingController: NSObject {
    struct Address: Equatable { let interface: String; let ip: String }
    private struct Pairing: Codable { let accessCode: String; let sessionSecret: String }
    var onStateChange: (() -> Void)?
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: "deviceSharingEnabled") }
    private var process: Process?
    private var monitor: Timer?
    private var generation = 0
    private var currentAddress: Address?
    private var addresses: [Address] = []
    private var readyURL: URL?
    private var pairing: Pairing?
    private var lastLaunch = Date.distantPast
    private var statusMessage = "设备共享尚未开启"
    private var instructions: NSWindow?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let urlLabel = NSTextField(labelWithString: "—")
    private let codeLabel = NSTextField(labelWithString: "—")
    private let networkPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let copyButton = NSButton(title: "复制地址", target: nil, action: nil)
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 2
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    func startIfEnabled() {
        guard isEnabled else { return }
        startMonitor()
        ensureRunning()
    }
    func showInstructions() {
        if instructions == nil { makeInstructions() }
        UserDefaults.standard.set(true, forKey: "deviceSharingEnabled")
        onStateChange?()
        startMonitor()
        ensureRunning()
        updateInstructions()
        NSApp.activate(ignoringOtherApps: true)
        instructions?.makeKeyAndOrderFront(nil)
    }
    func disable() {
        UserDefaults.standard.set(false, forKey: "deviceSharingEnabled")
        monitor?.invalidate(); monitor = nil
        stopOwnedProcess()
        statusMessage = "设备共享已关闭"
        updateInstructions()
        onStateChange?()
    }
    /// Preserve the user's opt-in for the next app launch, but close the bridge now.
    func stop() {
        monitor?.invalidate(); monitor = nil
        stopOwnedProcess()
        session.invalidateAndCancel()
        instructions?.close()
    }
    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureRunning() }
        }
    }
    private func ensureRunning() {
        guard isEnabled else { return }
        let discovered = Self.privateAddresses()
        if discovered != addresses { addresses = discovered; updateNetworkPicker() }
        let preferred = UserDefaults.standard.string(forKey: "deviceSharingInterface")
        guard let selected = addresses.first(where: { $0.interface == preferred }) ?? addresses.first else {
            stopOwnedProcess()
            statusMessage = "未找到 Wi-Fi 或以太网的局域网地址。连接网络后会自动重试。"
            updateInstructions(); return
        }
        if process?.isRunning == true && currentAddress == selected {
            if readyURL == nil { checkHealth(generation: generation, address: selected, attempt: 0) }
            return
        }
        if process != nil { stopOwnedProcess() }
        guard Date().timeIntervalSince(lastLaunch) >= 3 else { return }
        lastLaunch = Date()
        do {
            let config = try pairingConfiguration()
            pairing = config.value
            guard let resources = Bundle.main.resourceURL else { throw RuntimeIssue("应用资源不可用。") }
            let script = resources.appendingPathComponent("share_server.py")
            guard FileManager.default.fileExists(atPath: script.path) else { throw RuntimeIssue("设备共享组件缺失，请重新构建应用。") }
            let child = Process()
            child.executableURL = try PythonRuntime.executable()
            child.arguments = [script.path, "--bind", selected.ip, "--port", "8769", "--parent-pid",
                               String(ProcessInfo.processInfo.processIdentifier), "--config", config.url.path]
            child.currentDirectoryURL = resources
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            child.environment = environment
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] ended in
                Task { @MainActor in
                    guard let self, self.process === ended else { return }
                    self.process = nil; self.readyURL = nil
                    if self.isEnabled { self.statusMessage = "共享服务已停止，稍后重试。若持续失败，请检查端口 8769 是否被占用。" }
                    self.updateInstructions()
                }
            }
            try child.run()
            process = child; currentAddress = selected; generation += 1
            statusMessage = "正在启动设备共享…"
            updateInstructions()
            checkHealth(generation: generation, address: selected, attempt: 0)
        } catch {
            readyURL = nil
            statusMessage = (error as? RuntimeIssue)?.message ?? "无法启动设备共享，请检查 Python 3 和本地配置。"
            updateInstructions()
        }
    }
    private func stopOwnedProcess() {
        generation += 1
        let owned = process
        process = nil; currentAddress = nil; readyURL = nil
        if owned?.isRunning == true { owned?.terminate() }
    }
    private func checkHealth(generation expected: Int, address: Address, attempt: Int) {
        guard expected == generation, isEnabled, process?.isRunning == true else { return }
        let base = URL(string: "http://\(address.ip):8769/")!
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] data, response, _ in
            let http = response as? HTTPURLResponse
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
            let ready = http?.statusCode == 200 && body?["service"] == "gpt-lan-display"
            Task { @MainActor in
                guard let self, expected == self.generation, self.isEnabled, self.process?.isRunning == true else { return }
                if ready {
                    self.readyURL = base
                    self.statusMessage = "共享已开启。设备连接同一局域网后，即可打开下面的地址。"
                    self.updateInstructions()
                } else if attempt < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.checkHealth(generation: expected, address: address, attempt: attempt + 1)
                    }
                } else {
                    self.statusMessage = "共享服务暂未就绪，请检查网络或端口 8769。"
                    self.updateInstructions()
                }
            }
        }.resume()
    }
    private func pairingConfiguration() throws -> (url: URL, value: Pairing) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RuntimeIssue("无法访问本地应用配置目录。")
        }
        let directory = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.aiusagedashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("display-sharing.json")
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
                  metadata.st_size > 0, metadata.st_size <= 4096 else { throw RuntimeIssue("配对配置不是当前用户的普通文件。") }
            guard chmod(url.path, 0o600) == 0 else { throw RuntimeIssue("无法设置配对配置权限。") }
            let saved = try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: url))
            guard saved.accessCode.range(of: "^[0-9]{8}$", options: .regularExpression) != nil,
                  saved.sessionSecret.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw RuntimeIssue("配对配置格式无效，请关闭共享后修复 display-sharing.json。")
            }
            return (url, saved)
        }
        guard errno == ENOENT else { throw RuntimeIssue("无法读取配对配置。") }
        let value = Pairing(accessCode: String(format: "%08u", UInt32.random(in: 0...99_999_999)),
                            sessionSecret: (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())
        let bytes = try JSONEncoder().encode(value)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw RuntimeIssue("无法创建配对配置，请稍后重试。") }
        defer { Darwin.close(descriptor) }
        let count = bytes.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return -1 }; offset += written
            }
            return offset
        }
        guard count == bytes.count, fsync(descriptor) == 0 else {
            unlink(url.path); throw RuntimeIssue("配对配置未能保存。")
        }
        return (url, value)
    }
    static func privateAddresses() -> [Address] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var output: [Address] = [], cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = entry.pointee.ifa_flags
            guard name.range(of: "^en[0-9]+$", options: .regularExpression) != nil,
                  flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host), pieces = ip.split(separator: ".").compactMap { Int($0) }
            guard pieces.count == 4, pieces.allSatisfy({ (0...255).contains($0) }),
                  pieces[0] == 10 || (pieces[0] == 172 && (16...31).contains(pieces[1])) || (pieces[0] == 192 && pieces[1] == 168) else { continue }
            let value = Address(interface: name, ip: ip)
            if !output.contains(value) { output.append(value) }
        }
        return output.sorted { ($0.interface, $0.ip) < ($1.interface, $1.ip) }
    }
    private func makeInstructions() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "在 iPad / Kindle 打开"
        window.isReleasedWhenClosed = false
        window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
                                     stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
                                     stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        let title = NSTextField(labelWithString: "把看板放到另一块屏幕")
        title.font = .systemFont(ofSize: 22, weight: .semibold); stack.addArrangedSubview(title)
        statusLabel.font = .systemFont(ofSize: 13); statusLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(statusLabel)
        networkPicker.target = self; networkPicker.action = #selector(networkChanged); stack.addArrangedSubview(networkPicker)
        let addressTitle = NSTextField(labelWithString: "浏览器地址")
        addressTitle.textColor = .secondaryLabelColor; stack.addArrangedSubview(addressTitle)
        urlLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium); urlLabel.isSelectable = true
        stack.addArrangedSubview(urlLabel)
        copyButton.target = self; copyButton.action = #selector(copyAddress); stack.addArrangedSubview(copyButton)
        let codeTitle = NSTextField(labelWithString: "首次打开时输入配对码")
        codeTitle.textColor = .secondaryLabelColor; stack.addArrangedSubview(codeTitle)
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 32, weight: .medium); codeLabel.isSelectable = true
        stack.addArrangedSubview(codeLabel)
        let detail = NSTextField(wrappingLabelWithString: "设备与 Mac 需连接同一局域网。Mac 需保持唤醒，组件需保持运行。关闭本窗口不会停止共享；可在菜单中选择“关闭设备共享”。")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detail)
        instructions = window
        updateNetworkPicker(); updateInstructions()
    }
    private func updateNetworkPicker() {
        networkPicker.removeAllItems()
        for address in addresses { networkPicker.addItem(withTitle: address.ip) }
        let preferred = UserDefaults.standard.string(forKey: "deviceSharingInterface")
        if let index = addresses.firstIndex(where: { $0.interface == preferred }) { networkPicker.selectItem(at: index) }
        networkPicker.isHidden = addresses.count <= 1
    }
    private func updateInstructions() {
        statusLabel.stringValue = statusMessage
        urlLabel.stringValue = readyURL?.absoluteString ?? "—"
        codeLabel.stringValue = isEnabled && readyURL != nil ? pairing?.accessCode ?? "—" : "—"
        copyButton.isEnabled = readyURL != nil
    }
    @objc private func networkChanged() {
        let index = networkPicker.indexOfSelectedItem
        guard addresses.indices.contains(index) else { return }
        UserDefaults.standard.set(addresses[index].interface, forKey: "deviceSharingInterface")
        lastLaunch = .distantPast
        ensureRunning()
    }
    @objc private func copyAddress() {
        guard let url = readyURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
