import Foundation

/// Keeps each task's transcript in its own file beside the state file, one JSON message per
/// line, so a save costs what changed rather than the whole history.
///
/// A task that has run for hours holds thousands of messages. Encoding every task's transcript
/// on each save (every few seconds while output streams) took longer as the task grew and
/// left hundreds of megabytes of freed buffers behind. Now `state.json` holds tasks without
/// their messages, and a save rewrites a transcript file from its first changed message on:
/// usually only the few messages still streaming. A transcript whose array is the one last
/// written is skipped without reading it, since arrays share storage until changed.
///
/// A state file that still holds messages (written by an earlier version) is read as before;
/// its transcripts move to files on the next save. An earlier version reading the new state
/// file sees tasks without messages and loads their history from the harness.
///
/// Used from the main thread while loading and from the store's persistence queue after.
final class TranscriptArchive: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    /// What each file holds: the messages last written and where each one's line starts.
    private var written: [UUID: Written] = [:]

    private struct Written {
        var messages: [Message]
        /// The byte offset of each message's line, then the end of the file.
        var offsets: [UInt64]
    }

    /// `state.json` keeps its transcripts in `state-transcripts/`.
    init(stateFile: URL) {
        directory = stateFile.deletingLastPathComponent()
            .appendingPathComponent(stateFile.deletingPathExtension().lastPathComponent + "-transcripts", isDirectory: true)
    }

    func file(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".jsonl") }

    // MARK: Loading

    /// Fills in the messages of tasks saved without them. Files are read in parallel; a task
    /// that kept its messages in the state file keeps them.
    func load(into conversations: inout [Conversation]) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        // Files of tasks deleted by an earlier version, which did not know about them.
        let ids = Set(conversations.map(\.id.uuidString))
        for name in files where name.hasSuffix(".jsonl") && !ids.contains(String(name.dropLast(6))) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let wanted = conversations.enumerated().filter { $0.element.messages.isEmpty }.map { ($0.offset, $0.element.id) }
        guard !wanted.isEmpty else { return }
        var results = [(messages: [Message], offsets: [UInt64])?](repeating: nil, count: wanted.count)
        results.withUnsafeMutableBufferPointer { slots in
            let slots = slots
            DispatchQueue.concurrentPerform(iterations: wanted.count) { index in
                slots[index] = Self.read(file(for: wanted[index].1))
            }
        }
        lock.lock(); defer { lock.unlock() }
        for (slot, (index, id)) in wanted.enumerated() {
            guard let result = results[slot] else { continue }
            conversations[index].messages = result.messages
            written[id] = Written(messages: result.messages, offsets: result.offsets)
        }
    }

    /// The messages in a transcript file and where each line starts. A line that does not
    /// decode, such as one cut short by a crash, is skipped.
    static func read(_ file: URL) -> (messages: [Message], offsets: [UInt64])? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty else { return nil }
        var lines: [Range<Int>] = []
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for index in 0..<bytes.count where bytes[index] == 0x0A {
                if index > start { lines.append(start..<index) }
                start = index + 1
            }
            if start < bytes.count { lines.append(start..<bytes.count) }
        }
        let decoder = JSONDecoder()
        // One decode of the lines as an array is several times faster than one per line.
        var joined = Data(capacity: data.count + 2)
        joined.append(UInt8(ascii: "["))
        for (index, line) in lines.enumerated() {
            if index > 0 { joined.append(UInt8(ascii: ",")) }
            joined.append(data[line])
        }
        joined.append(UInt8(ascii: "]"))
        // A last line without its newline was cut short: appending after it would join the two.
        let intact = data.last == 0x0A
        if let messages = try? decoder.decode([Message].self, from: joined) {
            return (messages, lines.map { UInt64($0.lowerBound) } + [intact ? UInt64(data.count) : UInt64.max])
        }
        var messages: [Message] = []
        var offsets: [UInt64] = []
        for line in lines {
            guard let message = try? decoder.decode(Message.self, from: data[line]) else { continue }
            messages.append(message); offsets.append(UInt64(line.lowerBound))
        }
        // A damaged file is rewritten whole at the next save.
        return (messages, offsets + [UInt64.max])
    }

    // MARK: Saving

    /// Writes the transcripts that changed since the last save and removes those of deleted tasks.
    func save(_ conversations: [Conversation]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var live = Set<UUID>()
        for conversation in conversations {
            live.insert(conversation.id)
            try write(conversation.id, conversation.messages)
        }
        for id in written.keys where !live.contains(id) {
            try? FileManager.default.removeItem(at: file(for: id))
            written.removeValue(forKey: id)
        }
    }

    private func write(_ id: UUID, _ messages: [Message]) throws {
        let old = written[id]
        if let old, Self.sameStorage(old.messages, messages) { return }
        if old == nil, messages.isEmpty { return }
        let url = file(for: id)
        let encoder = JSONEncoder()
        // Everything before the first changed message is on disk already.
        var first = 0
        if let old, old.offsets.last != UInt64.max, FileManager.default.fileExists(atPath: url.path) {
            let limit = min(old.messages.count, messages.count)
            while first < limit, Self.same(old.messages[first], messages[first]) { first += 1 }
            if first == messages.count, first == old.messages.count { written[id]?.messages = messages; return }
        }
        var offsets = first == 0 ? [] : Array(old!.offsets.prefix(first))
        var position = first == 0 ? 0 : old!.offsets[first]
        var tail = Data()
        for message in messages[first...] {
            let line = try encoder.encode(message)
            offsets.append(position)
            tail.append(line); tail.append(0x0A)
            position += UInt64(line.count + 1)
        }
        offsets.append(position)
        if first == 0 {
            try tail.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: old!.offsets[first])
            try handle.seekToEnd()
            try handle.write(contentsOf: tail)
        }
        written[id] = Written(messages: messages, offsets: offsets)
    }

    /// Whether two arrays are the same storage: a transcript nothing has touched since it was written.
    static func sameStorage(_ lhs: [Message], _ rhs: [Message]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.isEmpty { return true }
        return lhs.withUnsafeBufferPointer { a in rhs.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
    }

    /// Whether a message is unchanged. Strings that share storage compare without reading them.
    static func same(_ a: Message, _ b: Message) -> Bool {
        a.id == b.id && a.kind == b.kind && a.status == b.status && a.toolID == b.toolID && a.createdAt == b.createdAt
            && a.text == b.text && a.detail == b.detail && a.attachments == b.attachments
    }
}
