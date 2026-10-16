import Combine
import XCTest

@testable import Crok

/// The hub that keeps one ConvexMobile subscription per query (see QueryHub for the lost-first-value race it avoids).
final class QueryHubTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int] = []
        private var _errors: [RelayError] = []
        var values: [Int] { lock.withLock { _values } }
        var errors: [RelayError] { lock.withLock { _errors } }
        func value(_ any: Any) { lock.withLock { _values.append(any as! Int) } }
        func error(_ error: RelayError) { lock.withLock { _errors.append(error) } }
    }

    final class FakeSubscription: @unchecked Sendable {
        var starts = 0
        var cancels = 0
        var deliver: (@Sendable (Any) -> Void)?
        var fail: (@Sendable (RelayError) -> Void)?

        func start(_ deliver: @escaping @Sendable (Any) -> Void, _ fail: @escaping @Sendable (RelayError) -> Void) -> AnyCancellable {
            starts += 1
            self.deliver = deliver
            self.fail = fail
            return AnyCancellable { [weak self] in self?.cancels += 1 }
        }
    }

    func testSharesOneSubscriptionAndReplaysTheLatestValue() {
        let hub = QueryHub()
        let fake = FakeSubscription()
        let first = Recorder()
        let second = Recorder()
        let key = QueryHub.key("sessions:get", ["sessionDocId": .string("s1")])
        hub.attach(key: key, id: UUID(), onValue: first.value, onError: first.error, start: fake.start)
        fake.deliver?(1)
        hub.attach(key: key, id: UUID(), onValue: second.value, onError: second.error, start: fake.start)
        XCTAssertEqual(fake.starts, 1, "the second screen shares the first subscription")
        XCTAssertEqual(second.values, [1], "and gets the value it would otherwise have missed")
        fake.deliver?(2)
        XCTAssertEqual(first.values, [1, 2])
        XCTAssertEqual(second.values, [1, 2])
    }

    func testDifferentArgumentsAreDifferentQueries() {
        XCTAssertNotEqual(
            QueryHub.key("sessions:get", ["sessionDocId": .string("a")]), QueryHub.key("sessions:get", ["sessionDocId": .string("b")]))
        XCTAssertEqual(
            QueryHub.key("x", ["a": .number(1), "b": .bool(true)]), QueryHub.key("x", ["b": .bool(true), "a": .number(1)]),
            "argument order does not matter")
    }

    func testAFailureReachesEveryObserverAndTheNextAttachStartsAgain() {
        let hub = QueryHub()
        let fake = FakeSubscription()
        let a = Recorder()
        let b = Recorder()
        hub.attach(key: "k", id: UUID(), onValue: a.value, onError: a.error, start: fake.start)
        hub.attach(key: "k", id: UUID(), onValue: b.value, onError: b.error, start: fake.start)
        fake.fail?(RelayError(.notFound, "gone"))
        XCTAssertEqual(a.errors.map(\.code), [.notFound])
        XCTAssertEqual(b.errors.map(\.code), [.notFound])
        XCTAssertEqual(hub.count, 0)
        hub.attach(key: "k", id: UUID(), onValue: a.value, onError: a.error, start: fake.start)
        XCTAssertEqual(fake.starts, 2)
    }

    func testASilentStreamIsReportedAsStalled() async {
        let silent = RelayStream<Int> { _ in }
        do {
            for try await _ in StallGuard.wrap(silent, timeout: .milliseconds(100)) {}
            XCTFail("expected a stall")
        } catch {
            XCTAssertTrue(error is StallGuard.Stalled)
        }
    }

    func testAStreamThatAnswersPassesThrough() async throws {
        let answering = RelayStream<Int> { continuation in
            continuation.yield(1)
            continuation.yield(2)
            continuation.finish()
        }
        var seen: [Int] = []
        for try await value in StallGuard.wrap(answering, timeout: .milliseconds(100)) { seen.append(value) }
        XCTAssertEqual(seen, [1, 2])
    }

    func testTheSubscriptionOutlivesItsLastObserverForTheGracePeriod() {
        let hub = QueryHub()
        let fake = FakeSubscription()
        let id = UUID()
        hub.attach(key: "k", id: id, onValue: { _ in }, onError: { _ in }, start: fake.start)
        hub.detach(key: "k", id: id)
        XCTAssertEqual(hub.count, 1, "kept for a moment so a reopened screen reuses it")
        let reopened = Recorder()
        fake.deliver?(7)
        hub.attach(key: "k", id: UUID(), onValue: reopened.value, onError: reopened.error, start: fake.start)
        XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(reopened.values, [7])
    }
}
