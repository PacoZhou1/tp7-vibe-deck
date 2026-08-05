import Foundation

enum Formatters {
    static let eventTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func sampleRate(_ value: Double) -> String {
        guard value > 0 else { return "-" }
        return "\(Int(value.rounded())) Hz"
    }
}
