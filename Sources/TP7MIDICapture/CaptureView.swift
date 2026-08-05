import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var recorder: MIDICaptureRecorder

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TP-7 MIDI Capture")
                    .font(.system(size: 22, weight: .semibold))
                Text(recorder.status)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(recorder.isRecording ? "Stop" : "Record") {
                recorder.isRecording ? recorder.stop() : recorder.start()
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)

            Button("Clear") {
                recorder.clear()
            }
            .buttonStyle(.bordered)

            Button("Export JSON") {
                recorder.exportJSON()
            }
            .buttonStyle(.bordered)

            Button("Export CSV") {
                recorder.exportCSV()
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }

    private var content: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            eventTable
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Markers")
                    .font(.headline)
                Text("Press a marker before moving the TP-7 control. The marker is saved in the export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                markerButton("Up")
                markerButton("Down")
                markerButton("Forward")
                markerButton("Backward")
                markerButton("Plus")
                markerButton("Minus")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("MIDI Sources")
                    .font(.headline)
                if recorder.endpoints.isEmpty {
                    Text("Press Record to scan sources.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recorder.endpoints, id: \.self) { endpoint in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(endpoint.localizedCaseInsensitiveContains("TP-7") ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 8, height: 8)
                            Text(endpoint)
                                .lineLimit(1)
                        }
                        .font(.system(size: 13))
                    }
                }
            }

            Spacer()
        }
        .padding(18)
        .frame(width: 230)
    }

    private func markerButton(_ title: String) -> some View {
        Button {
            recorder.addMarker(title)
        } label: {
            HStack {
                Image(systemName: "flag")
                Text(title)
                Spacer()
            }
        }
        .buttonStyle(.bordered)
    }

    private var eventTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(recorder.events.count) events")
                    .font(.headline)
                Spacer()
                Text("Newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Table(recorder.events) {
                TableColumn("#") { event in
                    Text("\(event.index)")
                        .monospacedDigit()
                }
                .width(48)

                TableColumn("ms") { event in
                    Text(String(format: "%.1f", event.deltaMilliseconds))
                        .monospacedDigit()
                }
                .width(82)

                TableColumn("Endpoint") { event in
                    Text(event.endpointName)
                        .lineLimit(1)
                }
                .width(min: 140, ideal: 190)

                TableColumn("Parsed") { event in
                    Text(event.summary)
                        .fontWeight(event.kind == .marker ? .semibold : .regular)
                }
                .width(min: 260, ideal: 360)

                TableColumn("Raw") { event in
                    Text(event.rawHex)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 120, ideal: 180)
            }
        }
    }
}
