import Foundation

/// Response shape of the (unofficial) Cursor dashboard endpoint
/// POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
struct PeriodUsageResponse: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: PlanUsage?

    private enum CodingKeys: String, CodingKey {
        case billingCycleStart
        case billingCycleEnd
        case planUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billingCycleStart = try container.decodeLooseStringIfPresent(forKey: .billingCycleStart)
        billingCycleEnd = try container.decodeLooseStringIfPresent(forKey: .billingCycleEnd)
        planUsage = try container.decodeIfPresent(PlanUsage.self, forKey: .planUsage)
    }
}

struct PlanUsage: Decodable {
    let totalSpend: Double?
    let includedSpend: Double?
    let bonusSpend: Double?
    let limit: Double?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?

    private enum CodingKeys: String, CodingKey {
        case totalSpend
        case includedSpend
        case bonusSpend
        case limit
        case autoPercentUsed
        case apiPercentUsed
        case totalPercentUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSpend = try container.decodeLooseDoubleIfPresent(forKey: .totalSpend)
        includedSpend = try container.decodeLooseDoubleIfPresent(forKey: .includedSpend)
        bonusSpend = try container.decodeLooseDoubleIfPresent(forKey: .bonusSpend)
        limit = try container.decodeLooseDoubleIfPresent(forKey: .limit)
        autoPercentUsed = try container.decodeLooseDoubleIfPresent(forKey: .autoPercentUsed)
        apiPercentUsed = try container.decodeLooseDoubleIfPresent(forKey: .apiPercentUsed)
        totalPercentUsed = try container.decodeLooseDoubleIfPresent(forKey: .totalPercentUsed)
    }
}

/// Normalized snapshot the rest of the app works with.
struct UsageSnapshot {
    let fetchedAt: Date
    let cycleStartMs: Double
    let cycleEndMs: Double
    let totalPercentUsed: Double
    let autoPercentUsed: Double
    let apiPercentUsed: Double
    let totalSpendUSD: Double

    var remainingPercent: Double { max(0, 100 - totalPercentUsed) }

    var cycleStartDate: Date { Date(timeIntervalSince1970: cycleStartMs / 1000.0) }
    var cycleEndDate: Date { Date(timeIntervalSince1970: cycleEndMs / 1000.0) }

    /// Cursor used to send cycle bounds as millisecond strings. Current responses use RFC3339.
    static func epochMillis(from raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return 0 }
        if let number = Double(raw) {
            return number < 1_000_000_000_000 ? number * 1000 : number
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return date.timeIntervalSince1970 * 1000
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) {
            return date.timeIntervalSince1970 * 1000
        }
        return 0
    }

    /// One-line menu text: «Оплачен до: 20.07 14:00 (1 день)».
    func cycleResetMenuLine(at now: Date = Date()) -> String {
        let days = Self.daysUntil(cycleEnd: cycleEndDate, from: now)
        return L10n.cycleResetLine(Self.shortResetDate(cycleEndDate), Self.daysLabel(days))
    }

    static func daysUntil(cycleEnd: Date, from now: Date, workingDaysOnly: Bool = false) -> Int {
        let cal = Calendar.current
        let fromDay = cal.startOfDay(for: now)
        let toDay = cal.startOfDay(for: cycleEnd)
        guard fromDay < toDay else { return 0 }

        if !workingDaysOnly {
            return cal.dateComponents([.day], from: fromDay, to: toDay).day ?? 0
        }

        var count = 0
        var current = fromDay
        while current < toDay {
            let weekday = cal.component(.weekday, from: current)
            if weekday != 1, weekday != 7 {
                count += 1
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return count
    }

    static func daysLabel(_ days: Int) -> String {
        L10n.daysLabel(days)
    }

    static func shortResetDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f.string(from: date)
    }
}

enum UsageError: Error, Equatable, CustomStringConvertible {
    case noToken
    case sessionLocked
    case tokenExpired
    case http(Int, String)
    case decode(String)
    case network(String)

    var description: String {
        switch self {
        case .noToken:
            return L10n.errorNoToken
        case .sessionLocked:
            return L10n.errorSessionLocked
        case .tokenExpired:
            return L10n.errorTokenExpired
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .decode(let msg):
            return L10n.errorDecode(msg)
        case .network(let msg):
            return L10n.errorNetwork(msg)
        }
    }

    /// English text for the activity journal (always logged in English).
    var journalDescription: String {
        switch self {
        case .noToken:
            return "Cursor token not found. Sign in to the Cursor app."
        case .sessionLocked:
            return "Cursor session is sealed. Allow Keychain access to Cursor Safe Storage."
        case .tokenExpired:
            return "Cursor token expired. Open Cursor to refresh the session."
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .decode(let msg):
            return "Couldn't parse response: \(msg)"
        case .network(let msg):
            return "Network: \(msg)"
        }
    }
}

extension KeyedDecodingContainer {
    func decodeLooseStringIfPresent(forKey key: Key) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key) {
            return value.rounded() == value ? String(format: "%.0f", value) : String(value)
        }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected string or number")
        )
    }

    func decodeLooseDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let number = Double(value) { return number }
        throw DecodingError.typeMismatch(
            Double.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected number or numeric string")
        )
    }
}
