import SwiftUI
import AppKit
import os.log

@main
struct GlucoseBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var timer: Timer?
    var settingsWindow: NSWindow?
    private var currentTask: URLSessionDataTask?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlucoseBar", category: "network")
    private let dexcomClient = DexcomShareClient()

    private var retryCount: Int = 0
    private let maxRetries: Int = 3
    private var isRefreshing: Bool = false

    let kKeychainService = Bundle.main.bundleIdentifier ?? "com.yourapp.GlucoseBar"
    let kApiSecretAccount = "xDripApiSecret"
    let kDexcomPasswordAccount = "DexcomSharePassword"
    let kApiURLKey = "GlucoseBarApiURL"
    let kDataSourceKey = "GlucoseBarDataSource"
    let kDexcomUsernameKey = "DexcomShareUsername"
    let kDexcomRegionKey = "DexcomShareRegion"

    private let staleReadingThreshold: TimeInterval = 15 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button { button.title = "Loading..." }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Configure…",
                                action: #selector(openConfigure),
                                keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Refresh Now",
                                action: #selector(refreshNow),
                                keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit",
                                action: #selector(quitApp),
                                keyEquivalent: "q"))
        statusItem?.menu = menu

        fetchGlucoseData()
        startTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        currentTask?.cancel()
        timer?.invalidate()
    }

    private func startTimer() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: 1 * 60, repeats: true) { [weak self] _ in
            self?.fetchGlucoseData()
        }

        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc func openConfigure() {
        if let win = settingsWindow {
            win.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView()
        let hosting = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "GlucoseBar Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 525))
        window.isReleasedWhenClosed = false
        window.level = .floating

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            self?.settingsWindow = nil
        }

        settingsWindow = window

        DispatchQueue.main.async {
            window.center()
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func refreshNow() {
        retryCount = 0
        fetchGlucoseData()
    }

    @objc func quitApp() {
        currentTask?.cancel()
        NSApplication.shared.terminate(self)
    }

    func currentApiSecret() -> String? {
        do { return try Keychain.load(account: kApiSecretAccount, service: kKeychainService) }
        catch { return nil }
    }

    func currentDexcomPassword() -> String? {
        do { return try Keychain.load(account: kDexcomPasswordAccount, service: kKeychainService) }
        catch { return nil }
    }

    private var currentDataSource: DataSource {
        guard let rawValue = UserDefaults.standard.string(forKey: kDataSourceKey) else {
            return .xdrip
        }
        return DataSource(rawValue: rawValue) ?? .xdrip
    }

    func fetchGlucoseData() {
        guard !isRefreshing else {
            logger.debug("Fetch already in progress, skipping")
            return
        }

        isRefreshing = true

        switch currentDataSource {
        case .xdrip:
            fetchXDripData()
        case .dexcomShare:
            fetchDexcomShareData()
        }
    }

    private func fetchXDripData() {
        guard let urlString = UserDefaults.standard.string(forKey: kApiURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else {
            logger.warning("Invalid or missing API URL")
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.updateDisplay(sgv: nil, direction: nil, errorType: .configuration)
            }
            return
        }

        currentTask?.cancel()

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let s = currentApiSecret() {
            request.setValue(s, forHTTPHeaderField: "api-secret")
        }

        currentTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            defer {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                }
            }

            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                self.logger.debug("Request cancelled")
                return
            }

            guard let data = data, error == nil else {
                self.logger.error("Network error: \(error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    self.handleNetworkError()
                }
                return
            }

            guard let http = response as? HTTPURLResponse else {
                self.logger.error("Invalid HTTP response")
                DispatchQueue.main.async {
                    self.updateDisplay(sgv: nil, direction: nil, errorType: .network)
                }
                return
            }

            guard 200..<300 ~= http.statusCode else {
                self.logger.error("HTTP error: \(http.statusCode)")
                let errorType: ErrorType = http.statusCode == 401 ? .authentication : .server
                DispatchQueue.main.async {
                    self.updateDisplay(sgv: nil, direction: nil, errorType: errorType)
                }
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      !json.isEmpty,
                      let latest = json.first else {
                    self.logger.error("Invalid JSON structure or empty array")
                    DispatchQueue.main.async {
                        self.updateDisplay(sgv: nil, direction: nil, errorType: .data)
                    }
                    return
                }

                guard let sgv = latest["sgv"] as? Int else {
                    self.logger.error("Missing sgv field")
                    DispatchQueue.main.async {
                        self.updateDisplay(sgv: nil, direction: nil, errorType: .data)
                    }
                    return
                }

                if !(40...400).contains(sgv) {
                    self.logger.warning("SGV out of expected range: \(sgv)")
                }

                var isStale = false
                if let dateMs = latest["date"] as? TimeInterval {
                    let readingDate = Date(timeIntervalSince1970: dateMs / 1000)
                    let age = Date().timeIntervalSince(readingDate)
                    isStale = age > self.staleReadingThreshold
                    if isStale {
                        self.logger.warning("Reading is stale: \(age/60) minutes old")
                    }
                }

                let direction = latest["direction"] as? String

                DispatchQueue.main.async {
                    self.retryCount = 0
                    self.updateDisplay(sgv: sgv, direction: direction, isStale: isStale, errorType: nil)
                }
            } catch {
                self.logger.error("JSON parsing error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.updateDisplay(sgv: nil, direction: nil, errorType: .data)
                }
            }
        }

        currentTask?.resume()
    }

    private func fetchDexcomShareData() {
        guard let username = UserDefaults.standard.string(forKey: kDexcomUsernameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !username.isEmpty else {
            logger.warning("Dexcom username not configured")
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.updateDisplay(sgv: nil, direction: nil, errorType: .configuration)
            }
            return
        }

        guard let password = currentDexcomPassword() else {
            logger.warning("Dexcom password not configured")
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.updateDisplay(sgv: nil, direction: nil, errorType: .configuration)
            }
            return
        }

        let region = UserDefaults.standard.string(forKey: kDexcomRegionKey) ?? "us"

        Task {
            do {
                let reading = try await dexcomClient.fetchLatestReading(
                    username: username,
                    password: password,
                    region: region
                )

                let age = Date().timeIntervalSince(reading.displayTime)
                let isStale = age > self.staleReadingThreshold

                await MainActor.run {
                    self.isRefreshing = false
                    self.retryCount = 0
                    self.updateDisplay(
                        sgv: reading.value,
                        direction: reading.trend,
                        isStale: isStale,
                        errorType: nil
                    )
                }
            } catch DexcomShareError.authenticationFailed {
                self.logger.error("Dexcom authentication failed")
                await MainActor.run {
                    self.isRefreshing = false
                    self.updateDisplay(sgv: nil, direction: nil, errorType: .authentication)
                }
            } catch {
                self.logger.error("Dexcom fetch error: \(error.localizedDescription)")
                await MainActor.run {
                    self.isRefreshing = false
                    self.handleNetworkError()
                }
            }
        }
    }

    private func handleNetworkError() {
        if retryCount < maxRetries {
            retryCount += 1
            let delay = min(pow(2.0, Double(retryCount)), 30.0)
            logger.info("Retrying in \(delay)s (attempt \(self.retryCount)/\(self.maxRetries))")

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fetchGlucoseData()
            }
        } else {
            logger.error("Max retries reached")
            updateDisplay(sgv: nil, direction: nil, errorType: .network)
            retryCount = 0
        }
    }

    enum ErrorType {
        case configuration
        case network
        case authentication
        case server
        case data
    }

    func updateDisplay(sgv: Int?, direction: String?, isStale: Bool = false, errorType: ErrorType?) {
        guard let button = statusItem?.button else { return }

        if let errorType = errorType {
            switch errorType {
            case .configuration:
                button.title = "⚙️ --"
            case .authentication:
                button.title = "🔒 --"
            case .network, .server:
                button.title = "⚠️ --"
            case .data:
                button.title = "❓ --"
            }
            return
        }

        guard let sgv = sgv, let direction = direction else {
            button.title = "⚠️ --"
            return
        }

        let arrow = getArrow(for: direction)
        let staleIndicator = isStale ? "⏰ " : ""
        button.title = "\(staleIndicator)\(arrow) \(sgv)"
    }

    func getArrow(for direction: String) -> String {
        switch direction {
        case "SingleUp", "DoubleUp": return "↑"
        case "FortyFiveUp": return "↗"
        case "Flat": return "→"
        case "FortyFiveDown": return "↘"
        case "SingleDown", "DoubleDown": return "↓"
        default: return "→"
        }
    }
}
