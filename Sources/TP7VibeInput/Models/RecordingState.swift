import Foundation

enum RecordingState: Equatable {
    case idle
    case recording(startedAt: Date)
    case processing
    case error(String)

    var title: String {
        switch self {
        case .idle: "Idle"
        case .recording: "Recording"
        case .processing: "Processing"
        case .error: "Error"
        }
    }
}
