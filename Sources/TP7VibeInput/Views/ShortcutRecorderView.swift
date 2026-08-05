import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var shortcut: ShortcutBinding?
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shortcut?.displayName ?? "No shortcut recorded")
                    .foregroundStyle(shortcut == nil ? .secondary : .primary)
                Spacer()
                Button(isRecording ? "Press keys..." : "Record") {
                    isRecording = true
                }
            }

            if isRecording {
                ShortcutCaptureField { captured in
                    shortcut = captured
                    isRecording = false
                }
                .frame(height: 32)
            }
        }
    }
}

private struct ShortcutCaptureField: NSViewRepresentable {
    let onCapture: (ShortcutBinding) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class CaptureView: NSView {
    var onCapture: ((ShortcutBinding) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
        let cgFlags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        let display = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        onCapture?(
            ShortcutBinding(
                keyCode: event.keyCode,
                modifiersRawValue: cgFlags.rawValue,
                keyDisplay: display.isEmpty ? "Key \(event.keyCode)" : display
            )
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.stroke()
    }
}
