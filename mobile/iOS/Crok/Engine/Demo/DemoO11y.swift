import Foundation

/// The o11y tab in demo mode (mobile/DESIGN.md "o11y", Demo mode): pages from the bundled `o11y-demo.json`, which
/// `relay/scripts/o11y-demo.mjs` makes from real pages with the owner's data swapped out. Text goes through the
/// relay's own translations, times move to now, and a refresh only moves `builtAt`.
///
/// `-CrokDemoO11y forbidden|unconfigured` shows those states instead (UI tests).
final class DemoO11y: O11yAPI, @unchecked Sendable {
    struct Fixture: Decodable {
        var builtAt: Double
        var pages: [String: O11yPage]
        var strings: [String: [String: String]]
    }

    private let fixture: Fixture?
    private let forced: O11yPageState.State?
    private let lock = NSLock()
    private var builtAt: [String: Date] = [:]
    private var sinks: [UUID: (key: String, send: @Sendable () -> Void)] = [:]
    private let now: @Sendable () -> Date

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        forced = defaults.string(forKey: "CrokDemoO11y").flatMap(O11yPageState.State.init(rawValue:))
        fixture = bundle.url(forResource: "o11y-demo", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Fixture.self, from: $0) }
    }

    /// The fixture's text in `lang`: a known string, else each " · " part that is known.
    func translate(_ text: String, lang: String) -> String {
        guard lang != "en", let fixture else { return text }
        if let whole = fixture.strings[text]?[lang] { return whole }
        guard text.contains(" · ") else { return text }
        return text.components(separatedBy: " · ").map { fixture.strings[$0]?[lang] ?? $0 }.joined(separator: " · ")
    }

    func state(_ id: String, range: String?, lang: String) -> O11yPageState {
        if let forced, forced != .ok { return O11yPageState(state: forced) }
        guard let fixture, let base = fixture.pages[id] else {
            return O11yPageState(state: .ok, page: nil, builtAt: nil, refreshing: false, error: nil)
        }
        let key = "\(id)|\(lang)"
        let built = lock.withLock { builtAt[key] } ?? now().addingTimeInterval(-30)
        let shift = built.timeIntervalSince1970 * 1000 - fixture.builtAt
        var page = base.mapText { translate($0, lang: lang) }.shifted(by: shift)
        page.builtAt = built.timeIntervalSince1970 * 1000
        if let range, page.ranges.contains(range) { page.range = range }
        return O11yPageState(state: .ok, page: page, builtAt: page.builtAt, refreshing: false, error: nil)
    }

    func page(_ id: String, range: String?, lang: String) -> RelayStream<O11yPageState> {
        AsyncThrowingStream { continuation in
            let sinkId = UUID()
            let key = "\(id)|\(lang)"
            let send: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                continuation.yield(self.state(id, range: range, lang: lang))
            }
            lock.withLock { sinks[sinkId] = (key, send) }
            send()
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.sinks.removeValue(forKey: sinkId) }
            }
        }
    }

    func refresh(_ id: String, range: String?, lang: String, force: Bool) async throws -> O11yRefreshResult {
        if let forced, forced != .ok {
            throw RelayError(forced == .forbidden ? .forbidden : .notConfigured, "")
        }
        try await Task.sleep(for: .milliseconds(400))
        let key = "\(id)|\(lang)"
        let date = now()
        let listeners = lock.withLock { () -> [@Sendable () -> Void] in
            builtAt[key] = date
            return sinks.values.filter { $0.key == key }.map(\.send)
        }
        for send in listeners { send() }
        return O11yRefreshResult(status: "built", builtAt: date.timeIntervalSince1970 * 1000, error: nil)
    }
}
