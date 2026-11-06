import Foundation

/// Starts only this app's bundled local service; never terminates a reused service.
@MainActor
final class BackendController {
    private var process: Process?
    private var checking = false
    private var stopping = false
    private var lastLaunch = Date.distantPast
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    func ensureRunning() {
        guard !checking, !stopping else { return }
        checking = true
        let url = URL(string: "http://127.0.0.1:8768/api/health")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        session.dataTask(with: request) { [weak self] data, response, _ in
            let http = response as? HTTPURLResponse
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]
            let healthy = http?.statusCode == 200 && body?["service"] == "gpt-mac-dashboard"
            Task { @MainActor in
                guard let self = self else { return }
                self.checking = false
                if !healthy && !self.stopping { self.startIfNeeded() }
            }
        }.resume()
    }

    private func startIfNeeded() {
        guard process?.isRunning != true, Date().timeIntervalSince(lastLaunch) > 8,
              let resources = Bundle.main.resourceURL else { return }
        let script = resources.appendingPathComponent("server.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return }
        lastLaunch = Date()
        let child = Process()
        guard let python = try? PythonRuntime.executable() else { return }
        child.executableURL = python
        child.arguments = [script.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        child.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self = self else { return }
                if self.process === ended { self.process = nil }
            }
        }
        do {
            try child.run()
            process = child
        } catch {
            process = nil
        }
    }

    func stop() {
        stopping = true
        session.invalidateAndCancel()
        if let child = process, child.isRunning { child.terminate() }
        process = nil
    }
}
