import Foundation

/// Follows `~/.crok/config.toml` while the app runs. The terminal writes the same file, so a
/// setting changed there (today: the interface language) applies here without a relaunch, the
/// way the terminal follows a change made here.
///
/// It stats the file every `interval` seconds and reads it only when the stamp moves. Both apps
/// replace the file atomically, so a moved stamp always means a complete new file. The desktop's
/// own writes move the stamp too; re-applying them is a no-op.
final class ConfigFileWatcher {
    static let shared = ConfigFileWatcher(url: GrokPaths.configFile)
    static let interval: TimeInterval = 2

    /// A file's identity from the outside: existence, modification date, and size.
    struct Stamp: Equatable {
        var exists = false
        var modified: Date?
        var size: UInt64 = 0

        static func of(_ url: URL) -> Stamp {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return Stamp() }
            return Stamp(exists: true, modified: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    let url: URL
    private let queue = DispatchQueue(label: "dev.chenli.crok.desktop.config-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var last: Stamp

    /// Starts from the file's current state, so the first check only fires on a later edit.
    init(url: URL) {
        self.url = url
        last = Stamp.of(url)
    }

    deinit { timer?.cancel() }

    /// Polls on a utility queue and calls `apply` on the main thread with the changed file.
    func start(apply: @escaping (GrokConfig) -> Void) {
        queue.sync {
            timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in
                guard let self, let config = self.checkOnQueue() else { return }
                DispatchQueue.main.async { apply(config) }
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
    }

    /// One check, now: the file's config when it changed since the last check, else nil.
    func check() -> GrokConfig? {
        queue.sync { checkOnQueue() }
    }

    private func checkOnQueue() -> GrokConfig? {
        let stamp = Stamp.of(url)
        guard stamp != last else { return nil }
        last = stamp
        return GrokConfig(url: url)
    }

    /// Everything the desktop follows from the shared file. Called at launch for the initial read
    /// and again for every change the watcher sees.
    static func apply(_ config: GrokConfig) {
        L10n.configure(fromConfig: config)
    }
}
