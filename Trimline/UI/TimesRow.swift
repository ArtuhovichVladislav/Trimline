import SwiftUI
import TrimlineCore

/// "from 00:24.15 · Clip 01:01.83 · to 01:25.98"; the outer times turn into fields on click.
struct TimesRow: View {
    private enum Metrics {
        static let spacing: CGFloat = 8
    }

    let timeFormat: TimeFormat

    @Environment(EditorModel.self) private var model

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            EditableHandleTime(handle: .start, timeFormat: timeFormat)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Clip \(timeFormat.string(from: model.selection.length))")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            EditableHandleTime(handle: .end, timeFormat: timeFormat)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

private struct EditableHandleTime: View {
    private enum Metrics {
        static let fieldMinWidth: CGFloat = 96
        // Focus requested while the field is still being inserted is dropped on macOS.
        static let focusDelay: Duration = .milliseconds(50)
    }

    let handle: EditorModel.TrimHandle
    let timeFormat: TimeFormat

    @Environment(EditorModel.self) private var model
    @Environment(InteractionState.self) private var interaction
    @State private var isEditing = false
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var time: String {
        timeFormat.string(from: model.handleTime(handle))
    }

    private var name: Text {
        handle == .start ? Text("Clip start") : Text("Clip end")
    }

    var body: some View {
        if isEditing {
            field
        } else {
            Button(action: beginEditing) {
                caption
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(Text(verbatim: time))
        }
    }

    private var caption: Text {
        switch handle {
        case .start: Text("from \(time)")
        case .end: Text("to \(time)")
        }
    }

    private var field: some View {
        TextField(text: $text) { name }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .foregroundStyle(.primary)
            .multilineTextAlignment(handle == .start ? .leading : .trailing)
            .frame(minWidth: Metrics.fieldMinWidth)
            .fixedSize()
            .focused($isFocused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .task {
                try? await Task.sleep(for: Metrics.focusDelay)
                isFocused = true
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    interaction.isEditingText = true
                } else {
                    commit()
                }
            }
            // Closing or replacing the file removes the field without it losing focus first.
            .onDisappear {
                if isEditing {
                    finishEditing()
                }
            }
    }

    private func beginEditing() {
        text = time
        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        finishEditing()
        guard let typed = timeFormat.time(from: text) else { return }
        model.setHandle(handle, to: typed)
        if !model.isPlaying {
            model.seek(to: model.handleTime(handle))
        }
    }

    private func cancel() {
        finishEditing()
    }

    private func finishEditing() {
        isEditing = false
        interaction.isEditingText = false
    }
}
