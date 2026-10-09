import SwiftUI
import AppKit

struct ConversationView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var attachments: PromptAttachmentsModel
    @State private var showPlan = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.conversation == nil { WelcomeView().frame(maxHeight: .infinity) }
                else { TranscriptView() }
            }
            // Files dropped anywhere on the conversation attach to the prompt.
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                store.project != nil && attachments.add(providers: providers)
            }
            .overlay { if dropTargeted && store.project != nil { AttachmentDropOverlay(cornerRadius: 18).padding(16) } }
            VStack(spacing: 10) {
                if let goal = store.run.goal { goalStatus(goal) }
                if !store.run.subagents.isEmpty {
                    Button { store.featurePanel = .agents } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2")
                            Text("\(store.run.subagents.count) subagents")
                            Spacer()
                            Text("View activity").foregroundStyle(Theme.muted)
                            Image(systemName: "chevron.right").font(.system(size: 10))
                        }.font(.system(size: 12, weight: .medium)).padding(11).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                if let approval = store.run.approvals.first { ApprovalCard(approval: approval) }
                if let question = store.run.questions.first { QuestionCard(request: question).id(question.id) }
                if !store.run.plan.isEmpty {
                    FoldableSection(isExpanded: $showPlan) {
                        HStack {
                            Image(systemName: "list.bullet.clipboard")
                            Text("Plan")
                            Spacer()
                            Text("\(store.run.plan.filter { $0.status == "completed" }.count) of \(store.run.plan.count)").foregroundStyle(Theme.muted)
                        }.font(.system(size: 13, weight: .medium))
                    } content: {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.run.plan) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: entry.status == "completed" ? "checkmark.circle.fill" : entry.status == "in_progress" ? "circle.dotted" : "circle")
                                        .foregroundStyle(entry.status == "completed" ? Theme.green : Theme.muted)
                                    Text(entry.content)
                                }
                            }
                        }.font(.system(size: 14)).padding(.leading, 42).padding(.trailing, 14).padding(.bottom, 12)
                    }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                ComposerView()
            }.frame(maxWidth: 860).padding(.horizontal, 32).padding(.bottom, 20).padding(.top, 12)
        }
        .task(id: "\(store.state.selectedProjectID?.uuidString ?? "")/\(store.state.selectedConversationID?.uuidString ?? "")") {
            await store.prepareSessionOptions()
        }
    }

    private func goalStatus(_ goal: GoalState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "scope").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(goal.objective).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(goal.status.replacingOccurrences(of: "_", with: " ").capitalized) · \(goal.tokensUsed.formatted()) tokens")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if goal.isActive { Button("Pause") { store.executeCommand(name: "goal", arguments: "pause") }.font(.system(size: 12)) }
            if goal.isPaused { Button("Resume") { store.executeCommand(name: "goal", arguments: "resume") }.font(.system(size: 12)) }
            Button { store.featurePanel = .goals } label: { Image(systemName: "ellipsis") }.buttonStyle(.plain).help("Manage goal")
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 11))
    }
}

struct ApprovalCard: View {
    @EnvironmentObject var store: AppStore
    var approval: Approval
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(approval.title, systemImage: "hand.raised").font(.system(size: 15, weight: .semibold))
            ReadOnlyTextView(text: approval.detail, style: .monospaced, sizing: .fitContent(maxHeight: 120))
            HStack {
                Spacer()
                ForEach(approval.options) { option in
                    Button(option.name) { store.approve(approval, option: option) }.buttonStyle(SubtleButtonStyle()).font(.system(size: 13, weight: .medium))
                }
            }
        }.padding(16).background(Theme.sidebar).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.4)))
    }
}

struct QuestionCard: View {
    @EnvironmentObject var store: AppStore
    var request: QuestionRequest
    @State private var selections: [String: Set<String>] = [:]
    @State private var notes: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("A question from Crok", systemImage: "bubble.left.and.bubble.right").font(.system(size: 15, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(request.questions) { question in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(question.question).font(.system(size: 14, weight: .medium))
                            ForEach(question.options, id: \.self) { option in
                                Button {
                                    if question.multiSelect {
                                        if selections[question.question, default: []].contains(option) { selections[question.question]?.remove(option) }
                                        else { selections[question.question, default: []].insert(option) }
                                    } else { selections[question.question] = [option] }
                                } label: {
                                    Label(option, systemImage: selections[question.question, default: []].contains(option) ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                                }.buttonStyle(.plain)
                            }
                            DesktopTextField("Or write a response…", text: Binding(get: { notes[question.question] ?? "" }, set: { notes[question.question] = $0 }), symbol: "text.bubble")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Skip") { store.answer(request, answers: [:], cancelled: true) }.buttonStyle(.plain)
                Button("Continue") {
                    var answers: [String: [String]] = [:]
                    for question in request.questions {
                        answers[question.question] = question.options.filter { selections[question.question, default: []].contains($0) }
                    }
                    store.answer(request, answers: answers, notes: notes)
                }.buttonStyle(SubtleButtonStyle()).disabled(request.questions.contains { (selections[$0.question] ?? []).isEmpty && (notes[$0.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }.font(.system(size: 13))
        }.padding(16).background(Theme.sidebar).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
