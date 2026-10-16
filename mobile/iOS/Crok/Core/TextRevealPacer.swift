import Foundation

/// Paces how much of a streaming reply is on screen, so text that arrives in bursts (the computer flushes about every
/// 0.75 s) reads as a steady flow instead of jumps.
///
/// The idea follows Telegram's streaming text reveal: learn how often chunks arrive, aim to show what is buffered by
/// the time the next chunk is due, and once the reply is finished show the rest within `finishWindow`.
struct TextRevealPacer: Sendable {
    /// Seconds to reveal whatever is left once the stream ends.
    static let finishWindow: Double = 0.3
    /// Never plan to spread a backlog over less than this, so a late chunk does not cause a burst.
    static let minimumHorizon: Double = 0.12
    /// Characters per second before two chunks have been seen.
    static let startRate: Double = 60
    /// Weight of the newest gap in the running average.
    static let gapSmoothing: Double = 0.35

    private(set) var shown: Double
    private(set) var length: Int
    private var meanGap: Double = 0.75
    private var lastArrival: Double?
    private var chunks = 0
    private var finishDeadline: Double?
    private var lastTick: Double?

    init(shown: Int, length: Int) {
        self.shown = Double(min(shown, length))
        self.length = length
    }

    var shownCount: Int { Int(shown.rounded(.down)) }
    var isFinishing: Bool { finishDeadline != nil }
    var isCaughtUp: Bool { shownCount >= length }
    /// Finished streaming and everything is on screen: the view can drop the pacer.
    var isDone: Bool { isFinishing && isCaughtUp }

    /// New text arrived: the full text is now `newLength` characters long.
    mutating func receive(length newLength: Int, at time: Double) {
        if newLength > length {
            if let last = lastArrival {
                let gap = max(0.016, time - last)
                meanGap = Self.gapSmoothing * gap + (1 - Self.gapSmoothing) * meanGap
            }
            lastArrival = time
            chunks += 1
        }
        length = newLength
        if shown > Double(length) { shown = Double(length) }
    }

    /// The reply is complete: reveal the rest within `finishWindow`.
    mutating func finish(at time: Double) {
        if finishDeadline == nil { finishDeadline = time + Self.finishWindow }
    }

    /// Advances to `time` and returns how many characters to show.
    @discardableResult
    mutating func advance(to time: Double) -> Int {
        let dt = min(max(0, time - (lastTick ?? time)), 0.1)
        lastTick = time
        let backlog = Double(length) - shown
        guard backlog > 0 else { return shownCount }
        let rate: Double
        if let deadline = finishDeadline {
            rate = backlog / max(deadline - time, 1.0 / 120)
        } else if chunks < 2 || lastArrival == nil {
            rate = Self.startRate
        } else {
            let nextChunkDue = (lastArrival ?? time) + meanGap
            rate = backlog / max(Self.minimumHorizon, nextChunkDue - time)
        }
        shown = min(Double(length), shown + rate * dt)
        if let deadline = finishDeadline, time >= deadline { shown = Double(length) }
        return shownCount
    }
}
