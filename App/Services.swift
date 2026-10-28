import Foundation
import Combine
import UserNotifications
import GarageCore

struct LookupService {
    func lookup(_ kind: DeadlineKind, plate: String) async throws -> Deadline {
        let address = kind == .vignette
            ? "https://check.bgtoll.bg/check/vignette/plate/BG/\(plate)"
            : "https://garage.karaybe.com/app/api/public-tools.php?tool=insurance"
        var request = URLRequest(url: URL(string: address)!)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if kind == .insurance {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("fetch", forHTTPHeaderField: "X-Requested-With")
            request.httpBody = Data("plate=\(plate)".utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        if kind == .vignette { return try Responses.vignette(data, plate: plate) }
        return try Responses.insurance(data, plate: plate)
    }
}

enum LocalStorage {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyGarage/cars.json")
    }
    static func load() throws -> [Car] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Car].self, from: Data(contentsOf: url))
    }
    static func save(_ cars: [Car]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
        try JSONEncoder().encode(cars).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

actor ReminderService {
    private let center = UNUserNotificationCenter.current()
    private var nextCars: [Car]?
    private var syncing = false

    func permission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    func status() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    // Coalesce overlapping updates so the final scheduled set always matches the latest saved cars.
    func sync(_ cars: [Car]) async throws {
        nextCars = cars
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while let snapshot = nextCars {
            nextCars = nil
            let old = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("garage.") }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: old)
            let authorization = await status()
            guard authorization == .authorized || authorization == .provisional else { continue }
            for reminder in ReminderPlanner.plan(cars: snapshot) {
                if nextCars != nil { break }
                let content = UNMutableNotificationContent()
                content.title = "\(reminder.plate) · \(reminder.kind.title)"
                content.body = reminder.daysBefore == 0
                    ? "Запазеният срок изтича днес (\(reminder.validTo.label))."
                    : "Запазеният срок изтича на \(reminder.validTo.label) — след \(reminder.daysBefore) дни."
                content.sound = .default
                var components = LocalDay.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireAt)
                components.calendar = LocalDay.calendar
                components.timeZone = LocalDay.calendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            }
        }
    }
    func test() async throws {
        let content = UNMutableNotificationContent()
        content.title = "Моят гараж"
        content.body = "Локалните известия работят. Това известие е създадено от телефона."
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "test.local-notification", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }
}

@MainActor final class GarageStore: ObservableObject {
    @Published private(set) var cars: [Car] = []
    @Published var message: String?
    @Published var checking: Set<UUID> = []
    @Published var errors: [UUID: String] = [:]
    @Published var notificationStatus = "Известията още не са разрешени."
    @Published private(set) var storageReady = true
    let reminders = ReminderService()
    init() {
        do { cars = try LocalStorage.load() }
        catch { storageReady = false; message = "Запазените данни не могат да се прочетат. Няма да бъдат презаписани. \(error.localizedDescription)" }
    }
    func car(_ id: UUID) -> Car? { cars.first { $0.id == id } }
    @discardableResult private func commit(_ updated: [Car]) -> Bool {
        guard storageReady else { message = "Записът е спрян, за да запазим съществуващия файл с данни."; return false }
        do {
            try LocalStorage.save(updated)
            cars = updated
            Task { await schedule() }
            return true
        } catch { message = "Неуспешен запис на телефона: \(error.localizedDescription)"; return false }
    }
    func add(plate: String, nickname: String) -> Bool {
        do {
            let normalized = try Plates.normalize(plate)
            guard !cars.contains(where: { $0.plate == normalized }) else { message = "Тази кола вече е добавена."; return false }
            return commit(cars + [Car(plate: normalized, nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines))])
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult func remove(_ id: UUID) -> Bool { let saved = commit(cars.filter { $0.id != id }); if saved { errors[id] = nil }; return saved }
    @discardableResult func apply(_ deadline: Deadline, to id: UUID) -> Bool {
        guard let index = cars.firstIndex(where: { $0.id == id }) else { return false }
        var copy = cars
        copy[index].apply(deadline)
        return commit(copy)
    }
    func check(_ id: UUID) async {
        guard let car = car(id), !checking.contains(id) else { return }
        checking.insert(id)
        errors[id] = nil
        defer { checking.remove(id) }
        var failures: [String] = []
        for kind in [DeadlineKind.vignette, .insurance] {
            do { apply(try await LookupService().lookup(kind, plate: car.plate), to: id) }
            catch { failures.append("\(kind.title): \(error.localizedDescription)") }
        }
        errors[id] = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
    func schedule() async {
        do { try await reminders.sync(cars) }
        catch { message = "Датите са записани, но известията не се планираха: \(error.localizedDescription)" }
        await refreshNotificationStatus()
    }
    func refreshNotificationStatus() async {
        let status = await reminders.status()
        switch status {
        case .authorized, .provisional: notificationStatus = "Известията са разрешени · 09:00 ч. по българско време"
        case .denied: notificationStatus = "Известията са изключени. Разреши ги от настройките на iPhone."
        default: notificationStatus = "Разреши известията, за да получаваш напомняния."
        }
    }
    func enableNotifications() async {
        do { _ = try await reminders.permission(); await schedule() }
        catch { message = error.localizedDescription }
    }
    func testNotification() async {
        do {
            guard try await reminders.permission() else { await refreshNotificationStatus(); message = "Известията са забранени. Разреши ги от Настройки."; return }
            try await reminders.test()
            message = "Тестовото известие е планирано след 5 секунди. Можеш да заключиш телефона."
        } catch { message = error.localizedDescription }
    }
}
