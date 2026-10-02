import AppKit
import FromoCore
import SwiftUI

@MainActor
final class AnswerForm: ObservableObject {
    @Published var startNext = true
}

@MainActor
final class AnswerPanel: NSPanel {
    private var model: AnswerPanelModel
    private let form = AnswerForm()
    private let submit: (Command) -> Void
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(model: AnswerPanelModel, submit: @escaping (Command) -> Void) {
        self.model = model
        self.submit = submit
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                   styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        title = "Break's over"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnswerView(model: model, form: form) { [weak self] answer in self?.choose(answer) })
        contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        setContentSize(hosting.fittingSize)
        center()
    }

    private func choose(_ answer: Answer) {
        submit(model.command(answer: answer, startNext: form.startNext, shift: NSEvent.modifierFlags.contains(.shift)))
    }

    func update(model: AnswerPanelModel) {
        self.model = model
        let hosting = NSHostingView(rootView: AnswerView(model: model, form: form) { [weak self] answer in self?.choose(answer) })
        contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        setContentSize(hosting.fittingSize)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && handleKey(event) { return }
        super.sendEvent(event)
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { return true } // No Escape dismissal.
        if [36, 76].contains(event.keyCode), model.suggestion != nil { choose(.didSuggested); return true }
        let key = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
        if key == "y", model.suggestion != nil { choose(.didSuggested); return true }
        if let number = Int(key), (1...9).contains(number), model.other.indices.contains(number - 1) {
            choose(.other(model.other[number - 1])); return true
        }
        return false
    }
    override func cancelOperation(_ sender: Any?) {} // NSPanel's Escape action must not close the prompt.
    override func close() {} // Only the hideAnswerPanel effect removes it.
    func dismiss() { super.close() }
}

@MainActor
private struct AnswerView: View {
    let model: AnswerPanelModel
    @ObservedObject var form: AnswerForm
    let choose: (Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let task = model.suggestion {
                (Text("Did you do: ") + Text(task).bold() + Text("?"))
                Button("Yes, \(task)") { choose(.didSuggested) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("What did you do?")
            }
            ForEach(Array(model.other.enumerated()), id: \.offset) { index, item in
                Button("\(index + 1). \(item)") { choose(.other(item)) }
            }
            Toggle("Start next work session", isOn: $form.startNext)
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}
