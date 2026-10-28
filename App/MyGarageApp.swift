import SwiftUI
import UserNotifications
import GarageCore

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}

@main struct MyGarageApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = GarageStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            GarageView().environmentObject(store).tint(.teal)
                .task { await store.schedule() }
                .onChange(of: phase) { value in if value == .active { Task { await store.schedule() } } }
        }
    }
}

struct GarageView: View {
    @EnvironmentObject private var store: GarageStore
    @State private var adding = false
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("ТВОИТЕ КОЛИ. ТВОИТЕ СРОКОВЕ.", systemImage: "car.fill").font(.caption.bold()).foregroundStyle(.teal)
                        Text("Спокойно на пътя.").font(.title2.bold())
                        Text("Датите остават на телефона. Интернет е нужен само за нова проверка.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                if store.cars.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "car.side").font(.system(size: 48)).foregroundStyle(.teal)
                            Text("Добави първата си кола").font(.headline)
                            Text("Винетка, гражданска и преглед — на едно място.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("Добави автомобил") { adding = true }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                } else {
                    Section("Моите автомобили") {
                        ForEach(store.cars) { car in
                            NavigationLink { CarView(id: car.id) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(car.plate).font(.title3.monospaced().bold())
                                        Spacer()
                                        Image(systemName: "car.side.fill").foregroundStyle(.teal)
                                    }
                                    if !car.nickname.isEmpty { Text(car.nickname).font(.subheadline).foregroundStyle(.secondary) }
                                    ForEach(DeadlineKind.allCases) { kind in
                                        HStack { Text(kind.title).font(.caption); Spacer(); DeadlineBadge(deadline: car.deadline(kind)) }
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Моят гараж")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button { settings = true } label: { Image(systemName: "bell.badge") }.accessibilityLabel("Известия и настройки") }
                ToolbarItem(placement: .navigationBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Добави автомобил") }
            }
            .sheet(isPresented: $adding) { AddCarView() }
            .sheet(isPresented: $settings) { SettingsView() }
            .alert("Моят гараж", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("Добре") { store.message = nil } } message: { Text(store.message ?? "") }
        }
    }
}

struct DeadlineBadge: View {
    let deadline: Deadline
    var body: some View {
        if let day = deadline.validTo {
            let days = LocalDay.calendar.dateComponents([.day], from: LocalDay(date: Date()).date, to: day.date).day ?? 0
            Text(day.label).font(.caption.monospacedDigit().bold()).foregroundStyle(days < 0 ? Color.red : days <= 30 ? Color.orange : Color.teal)
        } else { Text(deadline.status == "not_found" ? "Не е намерена" : "Няма дата").font(.caption).foregroundStyle(.secondary) }
    }
}

struct AddCarView: View {
    @EnvironmentObject private var store: GarageStore
    @Environment(\.dismiss) private var dismiss
    @State private var plate = ""
    @State private var nickname = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Автомобил") {
                    TextField("Регистрационен номер", text: $plate).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Име — по желание", text: $nickname)
                }
                Section { Text("След добавянето натисни „Провери“. Можеш да въведеш сроковете и ръчно.").font(.footnote).foregroundStyle(.secondary) }
                if let error = store.message { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }.navigationTitle("Нова кола")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отказ") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Добави") { if store.add(plate: plate, nickname: nickname) { dismiss() } }.disabled(plate.isEmpty || !store.storageReady) }
                }
        }
    }
}

struct CarView: View {
    let id: UUID
    @EnvironmentObject private var store: GarageStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DeadlineKind?
    @State private var inspection = false
    @State private var deleting = false
    var body: some View {
        Group {
            if let car = store.car(id) {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(car.plate).font(.largeTitle.monospaced().bold())
                            if !car.nickname.isEmpty { Text(car.nickname).foregroundStyle(.secondary) }
                            Button { Task { await store.check(id); inspection = true } } label: {
                                HStack { if store.checking.contains(id) { ProgressView() }; Label("Провери сроковете", systemImage: "arrow.clockwise") }
                            }.buttonStyle(.borderedProminent).disabled(store.checking.contains(id))
                        }.padding(.vertical, 8)
                    }
                    if let error = store.errors[id] { Section { Label(error, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange) } }
                    ForEach(DeadlineKind.allCases) { kind in
                        let deadline = car.deadline(kind)
                        Section {
                            HStack { Label(kind.title, systemImage: kind.symbol); Spacer(); DeadlineBadge(deadline: deadline) }
                            if let checked = deadline.checkedAt { Text("Получено: \(checked.formatted(date: .numeric, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                            if let checked = deadline.sourceCheckedAt { Text("Дата на първоначалната справка: \(checked)").font(.caption).foregroundStyle(.secondary) }
                            Text(deadline.source).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Въведи дата") { editing = kind }
                                if kind == .inspection { Spacer(); Button("Провери ГТП") { inspection = true } }
                            }
                        }
                    }
                    Section { Text("Напомняния: 30, 7 и 1 ден предварително и в деня на изтичане, в 09:00 ч. по българско време. Разреши известията от настройките.").font(.footnote).foregroundStyle(.secondary) }
                    Section { Button("Премахни автомобила", role: .destructive) { deleting = true } }
                }.navigationTitle(car.nickname.isEmpty ? "Автомобил" : car.nickname)
                    .sheet(item: $editing) { kind in EditDeadlineView(carID: id, kind: kind, deadline: car.deadline(kind)) }
                    .sheet(isPresented: $inspection) { InspectionSheet(car: car) }
                    .confirmationDialog("Да премахна ли колата и нейните напомняния?", isPresented: $deleting, titleVisibility: .visible) {
                        Button("Премахни", role: .destructive) { if store.remove(id) { dismiss() } }
                    }
            } else { Text("Автомобилът е премахнат.") }
        }
    }
}

struct EditDeadlineView: View {
    let carID: UUID
    let kind: DeadlineKind
    @EnvironmentObject private var store: GarageStore
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date
    init(carID: UUID, kind: DeadlineKind, deadline: Deadline) { self.carID = carID; self.kind = kind; _day = State(initialValue: deadline.validTo?.date ?? Date()) }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Валидно до", selection: $day, displayedComponents: .date).environment(\.timeZone, LocalDay.calendar.timeZone)
                Text("Въведи крайната дата от документа. Записът ще бъде отбелязан като ръчен.").font(.footnote).foregroundStyle(.secondary)
                if let error = store.message { Text(error).font(.footnote).foregroundStyle(.red) }
            }.navigationTitle(kind.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отказ") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Запази") { if store.apply(Deadline(kind: kind, validTo: LocalDay(date: day), source: "Въведено от теб", checkedAt: Date(), status: "manual"), to: carID) { dismiss() } } }
                }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: GarageStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Локални напомняния") {
                    Text(store.notificationStatus).font(.subheadline)
                    Button("Разреши известия") { Task { await store.enableNotifications() } }
                    Button("Тестово известие след 5 секунди") { Task { await store.testNotification() } }
                    Button("Отвори настройките на iPhone") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    if let message = store.message { Text(message).font(.footnote) }
                }
                Section("На твоя телефон") {
                    Text("Няма профил, реклама, аналитика или собствен сървър. Колите и датите се пазят в приложението, без включване във файловия iCloud backup.")
                    Text("При проверка регистрационният номер се изпраща на БГТОЛ, Гараж или Globi. Техните справки могат да се променят или да изискват човешко потвърждение.")
                    Text("Планират се до 60 от най-близките известия. При отваряне и промяна на сроковете списъкът се обновява.")
                }.font(.footnote)
                Section("Тестова версия 0.1") { Text("Първият реален тест трябва да потвърди известията при заключен iPhone и проверката за ГТП. Безплатният подпис на приложението трябва да се подновява.").font(.footnote) }
            }.navigationTitle("Известия и данни")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
                .task { await store.refreshNotificationStatus() }
        }
    }
}
