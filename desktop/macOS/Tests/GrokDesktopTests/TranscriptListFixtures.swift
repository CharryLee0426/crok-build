import AppKit
import Foundation
@testable import GrokDesktop

/// Transcripts for the AppKit transcript's tests: one of every kind of row, and the long tasks
/// the list is built for.
enum TranscriptListFixtures {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// Every Markdown format a reply can hold.
    static let everyFormat = #"""
    # Heading one
    ## Heading two
    ### Heading three
    #### Heading four

    A paragraph with **bold**, *italic*, ***both***, ~~strikethrough~~, `inline code`, a [link](https://example.com/docs "Docs"), a bare URL https://example.org/path_(x), a footnote[^1], and inline math $E = mc^2$ and $\frac{a_1}{b}$. Prices are $5 and $10, not math.
    A second line after a single newline.

    - First bullet
    - Second bullet with `code`
      - Nested bullet
        - Third level
    - [x] A finished task
    - [ ] An open task

    1. **Install** the dependencies
    2. **Configure** the project:
       ```bash
       export PATH="$HOME/bin:$PATH"
       make build -j8
       ```
    3. Verify:
       $$
       \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
       $$

    | Option | Type | Default | Notes |
    |:-------|:----:|--------:|-------|
    | `timeout` | `Int` | 30 | seconds, see $t_{max}$ |
    | `retries` | `Int` | 3 | uses **exponential** backoff |
    | `mode` | `String` | "fast" | one of `fast`, `safe` |

    > A block quote with **bold** text
    > on two lines.

    > [!NOTE]
    > A note callout with a list:
    > - item one
    > - item two

    > [!WARNING]
    > A warning callout.

    ```swift
    struct Row: Identifiable {
        let id = UUID()
        var height: CGFloat = 44  // estimated until measured
        func top(after previous: Row) -> CGFloat { previous.height + 23 }
    }
    ```

    ```
    plain code without a language
    ```

    ---

    $$
    \int_{0}^{\infty} e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
    $$

    <details><summary>Inline HTML</summary>stays visible</details>

    Final paragraph.

    [^1]: The footnote's text.
    """#

    static let toolOutput = (0..<40).map { "test crate_7::case_\($0) ... ok (\(($0 * 7) % 90) ms)" }.joined(separator: "\n")

    /// One of every kind of row, in every state a saved task shows them in.
    static func showcase() -> [Message] {
        var at = base
        func message(_ kind: Message.Kind, _ text: String, status: String? = nil, detail: String? = nil, tool: String? = nil) -> Message {
            at = at.addingTimeInterval(40)
            return Message(kind: kind, text: text, toolID: tool, status: status, detail: detail, createdAt: at)
        }
        return [
            message(.user, "Show me every kind of row"),
            message(.thought, "The reader asked for every kind of row. **First** the short ones, then the long reply.\n\nA second paragraph of reasoning with `code` in it."),
            message(.tool, "Read `Sources/GrokDesktop/TranscriptListView.swift`", status: "completed", detail: "import AppKit\nimport SwiftUI\n\nfinal class TranscriptListView: NSView {}", tool: "t1"),
            message(.tool, "Run `cargo test -p xai-grok-pager --release -- --nocapture --test-threads=1 transcript::rows::long_names_wrap_onto_a_second_line_of_the_title_when_they_must`",
                    status: "in_progress", detail: toolOutput, tool: "t2"),
            message(.tool, "Run `make deploy`", status: "failed", detail: "error: linking with `cc` failed", tool: "t3"),
            message(.tool, "List files", status: "pending", detail: "", tool: "t4"),
            message(.assistant, "A short reply with **bold** and `code`."),
            message(.system, "The harness stopped responding and was restarted."),
            message(.user, "A longer prompt that wraps onto more than one line when the window is narrow enough, to see how the bubble sizes itself.\nIt also has a second paragraph."),
            message(.assistant, everyFormat),
            message(.user, "Thanks"),
            message(.assistant, "You're welcome."),
        ]
    }

    /// A picture a tool returned or a prompt carried, as the transcript keeps it: a thumbnail and its size.
    static func image(_ name: String, width: Int, height: Int, hue: CGFloat, origin: MessageAttachment.Origin? = .tool) -> MessageAttachment {
        let picture = NSImage(size: NSSize(width: width / 4, height: height / 4), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            rect.fill()
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)).fill()
            return true
        }
        let data = picture.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        return MessageAttachment(kind: .image, name: name, thumbnail: data, mimeType: "image/png", pixelWidth: width, pixelHeight: height, origin: origin)
    }

    /// Rows that carry pictures and files: a prompt with both, a command that returned several
    /// screenshots, one that returned a single one, and a reply with a generated image.
    static func withAttachments() -> [Message] {
        let shots = (0..<8).map { image("Screenshot \($0 + 1).png", width: [1600, 900, 1200][$0 % 3], height: [900, 1600, 1200][$0 % 3], hue: CGFloat($0) / 8) }
        return [
            Message(kind: .user, text: "What is wrong in these?", createdAt: base,
                    attachments: [image("before.png", width: 1200, height: 800, hue: 0.1, origin: nil), image("after.png", width: 800, height: 1200, hue: 0.6, origin: nil),
                                  MessageAttachment(kind: .file, name: "crash-report-2026-10-07.log", path: "/tmp/crash-report-2026-10-07.log"),
                                  MessageAttachment(kind: .folder, name: "Sources", path: "/tmp/Sources")]),
            Message(kind: .tool, text: "Take screenshots of `every window`", toolID: "shots", status: "completed", detail: "Captured 8 windows.", createdAt: base, attachments: shots),
            Message(kind: .tool, text: "Read `diagram.png`", toolID: "one", status: "completed", detail: "", createdAt: base, attachments: [shots[0]]),
            Message(kind: .assistant, text: "Here is the corrected layout.", createdAt: base, attachments: [image("layout.png", width: 1024, height: 1024, hue: 0.8, origin: .generated)]),
            Message(kind: .assistant, text: "", createdAt: base, attachments: [image("only.png", width: 640, height: 360, hue: 0.3, origin: .reply)]),
        ]
    }

    /// Reasoning of three lengths: a line, a paragraph, a page.
    static func thought(_ index: Int) -> String {
        switch index % 3 {
        case 0: return "Round \(index): check `crate_\(index % 37)` before touching the tests."
        case 1: return (0..<6).map { "Step \($0 + 1) of round \(index): the last run left \(index % 5) warnings, so compare the change in `src/lib.rs` with module \($0)." }.joined(separator: " ")
        default: return MarkdownTestDocuments.thinking(lines: 60 + index % 40)
        }
    }

    /// A long session: `rounds` rounds of reasoning (short, medium, long in turn), commands that
    /// ran together with outputs of three sizes, and a reply that every so often holds every
    /// Markdown format. `thoughtsPerRound` reasoning blocks open each round.
    static func longSession(rounds: Int, thoughtsPerRound: Int = 1, commandsPerRound: Int = 3) -> [Message] {
        var messages: [Message] = [Message(kind: .user, text: "Run the whole suite, fix what fails, repeat.", createdAt: base)]
        messages.reserveCapacity(rounds * (thoughtsPerRound + commandsPerRound + 1) + 1)
        for round in 0..<rounds {
            let at = base.addingTimeInterval(Double(round) * 3)
            for thought in 0..<thoughtsPerRound {
                messages.append(Message(kind: .thought, text: self.thought(round * thoughtsPerRound + thought), createdAt: at))
            }
            for command in 0..<commandsPerRound {
                let lines = [3, 40, 600][(round + command) % 3]
                let output = (0..<lines).map { "test crate_\(round % 37)::case_\($0) ... ok (\((round * 7 + $0) % 90) ms)" }.joined(separator: "\n")
                messages.append(Message(kind: .tool, text: "Run `cargo test -p crate_\((round + command) % 37)`", toolID: "tool-\(round)-\(command)",
                                        status: "completed", detail: output, createdAt: at))
            }
            let reply: String
            switch round % 25 {
            case 7: reply = everyFormat
            case 16: reply = MarkdownTestDocuments.mixed(bytes: 6_000)
            default: reply = "Round \(round + 1) passed: **40 tests** in `crate_\(round % 37)`. Next I will look at `module_\(round % 11).rs`."
            }
            messages.append(Message(kind: .assistant, text: reply, createdAt: at))
        }
        return messages
    }
}
