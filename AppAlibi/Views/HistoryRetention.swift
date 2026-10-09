import Foundation

/// How long history is kept. Raw values are months; 0 keeps everything.
enum HistoryRetention: Int, CaseIterable, Identifiable {
    case forever = 0
    case month = 1
    case threeMonths = 3
    case sixMonths = 6
    case year = 12

    var id: Self { self }

    var title: String {
        switch self {
        case .forever: "Forever"
        case .month: "1 Month"
        case .threeMonths: "3 Months"
        case .sixMonths: "6 Months"
        case .year: "1 Year"
        }
    }

    /// History older than this goes. nil keeps everything.
    func cutoff(before now: Date, calendar: Calendar = .current) -> Date? {
        guard self != .forever else { return nil }
        return calendar.date(byAdding: .month, value: -rawValue, to: now)
    }

    /// Whether switching to `other` deletes anything that this setting keeps.
    func isLonger(than other: HistoryRetention) -> Bool {
        self == .forever ? other != .forever : other != .forever && rawValue > other.rawValue
    }
}
