import Foundation

public enum GarageError: LocalizedError {
    case invalidPlate, unexpectedResponse, wrongPlate, noDate
    public var errorDescription: String? {
        switch self {
        case .invalidPlate: return "Въведи стандартен български регистрационен номер."
        case .unexpectedResponse: return "Услугата върна непознат отговор. Запазените дати не са променени."
        case .wrongPlate: return "Справката е за друг регистрационен номер."
        case .noDate: return "Липсва потвърдена крайна дата."
        }
    }
}

public enum Plates {
    public static func normalize(_ input: String) throws -> String {
        let letters: [Character: Character] = ["А":"A", "В":"B", "Е":"E", "К":"K", "М":"M", "Н":"H", "О":"O", "Р":"P", "С":"C", "Т":"T", "У":"Y", "Х":"X"]
        let plate = String(input.uppercased().filter { !$0.isWhitespace && $0 != "-" }.map { letters[$0] ?? $0 })
        guard plate.range(of: "^[ABEKMHOPCTYX]{1,2}[0-9]{4}[ABEKMHOPCTYX]{1,2}$", options: .regularExpression) != nil else { throw GarageError.invalidPlate }
        return plate
    }
}

public struct LocalDay: Codable, Hashable, Comparable {
    public let iso: String
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
        return calendar
    }
    public init?(_ value: String) {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Self.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let result = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard result.year == parts[0], result.month == parts[1], result.day == parts[2] else { return nil }
        iso = value
    }
    public init(date: Date) {
        let c = Self.calendar.dateComponents([.year, .month, .day], from: date)
        iso = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public var date: Date {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        return Self.calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }
    public var label: String { let p = iso.split(separator: "-"); return "\(p[2]).\(p[1]).\(p[0])" }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.iso < rhs.iso }
    public static func parseBulgarian(_ value: String) -> Self? {
        guard let range = value.range(of: "[0-9]{2}\\.[0-9]{2}\\.[0-9]{4}", options: .regularExpression) else { return nil }
        let p = value[range].split(separator: ".")
        return Self("\(p[2])-\(p[1])-\(p[0])")
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let day = Self(value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid local date") }
        self = day
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(iso) }
}

public enum DeadlineKind: String, Codable, CaseIterable, Identifiable {
    case vignette, insurance, inspection
    public var id: String { rawValue }
    public var title: String {
        switch self { case .vignette: return "Винетка"; case .insurance: return "Гражданска отговорност"; case .inspection: return "Технически преглед" }
    }
    public var symbol: String {
        switch self { case .vignette: return "road.lanes"; case .insurance: return "shield.lefthalf.filled"; case .inspection: return "wrench.and.screwdriver" }
    }
}
public struct Deadline: Codable, Equatable {
    public var kind: DeadlineKind
    public var validTo: LocalDay?
    public var source: String
    public var checkedAt: Date?
    public var sourceCheckedAt: String?
    public var status: String
    public init(kind: DeadlineKind, validTo: LocalDay? = nil, source: String = "Няма данни", checkedAt: Date? = nil, sourceCheckedAt: String? = nil, status: String = "unknown") {
        self.kind = kind; self.validTo = validTo; self.source = source; self.checkedAt = checkedAt; self.sourceCheckedAt = sourceCheckedAt; self.status = status
    }
}
public struct Car: Codable, Identifiable, Equatable {
    public var id: UUID
    public var plate: String
    public var nickname: String
    public var deadlines: [Deadline]
    public init(id: UUID = UUID(), plate: String, nickname: String = "") {
        self.id = id; self.plate = plate; self.nickname = nickname
        deadlines = DeadlineKind.allCases.map { Deadline(kind: $0) }
    }
    public func deadline(_ kind: DeadlineKind) -> Deadline { deadlines.first { $0.kind == kind } ?? Deadline(kind: kind) }
    public mutating func apply(_ value: Deadline) { deadlines.removeAll { $0.kind == value.kind }; deadlines.append(value) }
}

public enum Responses {
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GarageError.unexpectedResponse }
        return json
    }
    public static func vignette(_ data: Data, plate: String, now: Date = Date()) throws -> Deadline {
        let json = try object(data)
        let status = json["status"] as? [String: Any]
        if json["ok"] as? Bool == false, json["vignette"] is NSNull, status?["message"] as? String == "public.ui.ok.noVignette" {
            return Deadline(kind: .vignette, source: "БГТОЛ", checkedAt: now, status: "not_found")
        }
        guard json["ok"] as? Bool == true, let v = json["vignette"] as? [String: Any], let active = v["statusBoolean"] as? Bool,
              let date = v["validityDateTo"] as? String, let day = LocalDay(String(date.prefix(10))) else { throw GarageError.unexpectedResponse }
        guard let returned = v["licensePlateNumber"] as? String, try Plates.normalize(returned) == plate else { throw GarageError.wrongPlate }
        return Deadline(kind: .vignette, validTo: day, source: "БГТОЛ", checkedAt: now, status: active ? "valid" : "not_active")
    }
    public static func insurance(_ data: Data, plate: String, now: Date = Date()) throws -> Deadline {
        let root = try object(data)
        let d = root["data"] as? [String: Any] ?? root
        guard root["ok"] as? Bool == true, let found = d["found"] as? Bool else { throw GarageError.unexpectedResponse }
        guard let returned = d["plate"] as? String, try Plates.normalize(returned) == plate else { throw GarageError.wrongPlate }
        if !found { return Deadline(kind: .insurance, source: "Гараж / Гаранционен фонд", checkedAt: now, status: "not_found") }
        guard let policies = d["policies"] as? [[String: Any]], !policies.isEmpty else { throw GarageError.noDate }
        let dates = policies.compactMap { ($0["dateTo"] as? String).flatMap { LocalDay.parseBulgarian($0) } }
        guard dates.count == policies.count, let last = dates.max() else { throw GarageError.noDate }
        return Deadline(kind: .insurance, validTo: last, source: "Гараж / Гаранционен фонд", checkedAt: now, status: "valid")
    }
    public static func inspection(_ text: String, plate: String, now: Date = Date()) throws -> Deadline {
        guard text.contains(plate) else { throw GarageError.wrongPlate }
        guard text.contains("Валиден ГТП"), let range = text.range(of: "Срок за следващ преглед"), let date = LocalDay.parseBulgarian(String(text[range.upperBound...].prefix(45))) else { throw GarageError.noDate }
        let sourceDate = text.components(separatedBy: "Проверката е извършена на").dropFirst().first?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces)
        return Deadline(kind: .inspection, validTo: date, source: "Globi / ИААА (може да е кеширана справка)", checkedAt: now, sourceCheckedAt: sourceDate, status: "valid")
    }
}

public struct Reminder: Identifiable {
    public let id: String
    public let plate: String
    public let kind: DeadlineKind
    public let fireAt: Date
    public let validTo: LocalDay
    public let daysBefore: Int
}
public enum ReminderPlanner {
    public static func plan(cars: [Car], now: Date = Date(), limit: Int = 60) -> [Reminder] {
        let calendar = LocalDay.calendar
        var reminders: [Reminder] = []
        for car in cars {
            for deadline in car.deadlines {
                guard let expiry = deadline.validTo, deadline.status != "not_found" else { continue }
                for days in [30, 7, 1, 0] {
                    guard let date = calendar.date(byAdding: .day, value: -days, to: expiry.date),
                          let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date), fire > now else { continue }
                    reminders.append(Reminder(id: "garage.\(car.id).\(deadline.kind.rawValue).\(days)", plate: car.plate, kind: deadline.kind, fireAt: fire, validTo: expiry, daysBefore: days))
                }
            }
        }
        return Array(reminders.sorted { $0.fireAt == $1.fireAt ? $0.id < $1.id : $0.fireAt < $1.fireAt }.prefix(max(0, limit)))
    }
}
