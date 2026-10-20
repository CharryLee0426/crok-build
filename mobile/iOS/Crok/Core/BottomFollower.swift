import Foundation

/// Whether the transcript keeps its end in sight (iOS 18+), decided from how far the end is below the visible bottom
/// edge and who is moving the scroll view.
///
/// It follows the end until the person scrolls away from it (inside a reply taller than the screen, above its end,
/// counts as away), and again once they scroll back, tap the scroll-to-bottom button or send. While it follows and
/// nobody is scrolling, anything that moves the end (rows measured after a lazy estimate, a reply growing, the composer
/// or keyboard changing height) asks for a pin back to the end. Resting past the end as the geometry tells it always
/// does. (A blank stretch the geometry cannot see, a stale height estimate taller than the rows, is caught by the view
/// model's blank-stretch check from the rows' real position.) Pins that keep missing stop after `maxMissedPins`, so a
/// layout that cannot settle never spins, and it stops following, so the scroll-to-bottom button shows.
struct BottomFollower: Equatable, Sendable {
    enum Phase: Sendable {
        /// Nothing moves the scroll view.
        case idle
        /// The person touches, drags or flings it.
        case user
        /// A programmatic scroll is animating (the button).
        case animating
    }

    /// How far from the end still counts as at the end, in points.
    static let slop: Double = 24
    /// Pins in a row that may miss the end before pinning stops and following with it (until the person scrolls, the
    /// button or a send asks again, or new content arrives).
    static let maxMissedPins = 8

    private(set) var follows = true
    /// How far the end is below the visible bottom edge (negative: above it, a blank stretch under the end).
    private(set) var distance: Double = 0
    private(set) var phase: Phase = .idle
    private(set) var missedPins = 0

    /// The end moved. True when the view should put it back in sight.
    mutating func geometryChanged(distance: Double) -> Bool {
        self.distance = distance
        switch phase {
        case .user:
            follows = distance <= Self.slop
            return false
        case .animating:
            return false
        case .idle:
            return settle()
        }
    }

    /// The scroll phase changed. True when the view should put the end back in sight.
    mutating func phaseChanged(_ phase: Phase) -> Bool {
        let wasUser = self.phase == .user
        self.phase = phase
        guard phase == .idle else {
            if phase == .user { missedPins = 0 }
            return false
        }
        if wasUser { follows = distance <= Self.slop }
        return settle()
    }

    /// The button or a send is taking the transcript to its end with an animation. Until it ends the geometry moves on
    /// its account, not as drift to pin; the scroll phase does not always report such an animation, so the caller ends
    /// it (`animationEnded`) if the phase never does.
    mutating func follow() {
        follows = true
        missedPins = 0
        phase = .animating
    }

    /// The button's or a send's animation is over. True when the view should pin the rest of the way.
    mutating func animationEnded() -> Bool {
        guard phase == .animating else { return false }
        phase = .idle
        return settle()
    }

    /// New content: pins may try again.
    mutating func contentChanged() {
        missedPins = 0
    }

    /// At rest: at the end, follow; past it, pin; above it, pin only while following.
    private mutating func settle() -> Bool {
        if abs(distance) <= Self.slop {
            follows = true
            missedPins = 0
            return false
        }
        if distance < 0 {
            follows = true
            return pin()
        }
        return follows && pin()
    }

    private mutating func pin() -> Bool {
        guard missedPins < Self.maxMissedPins else {
            // Away from the end and unable to get back on its own: the scroll-to-bottom button shows.
            follows = false
            return false
        }
        missedPins += 1
        return true
    }
}
