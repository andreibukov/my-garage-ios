import SwiftUI
import WebKit
import GarageCore

struct InspectionSheet: View {
    let car: Car
    @EnvironmentObject private var store: GarageStore
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Зареждам проверката…"
    @State private var attempt = UUID()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(car.plate).font(.headline.monospaced())
                    Text(status).font(.footnote)
                    Text("Ако се появи проверка за човек, потвърди я тук. При отказ можеш да въведеш датата ръчно.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                Divider()
                InspectionBrowser(plate: car.plate) { result in
                    switch result {
                    case .success(let deadline):
                        if store.apply(deadline, to: car.id) { status = "Запазено: ГТП до \(deadline.validTo?.label ?? "—")." }
                        else { status = "Получихме справката, но записът на телефона е неуспешен." }
                    case .failure(let error): status = error.localizedDescription
                    }
                }.id(attempt)
            }.navigationTitle("Проверка на ГТП").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Затвори") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Повтори") { status = "Зареждам проверката…"; attempt = UUID() } }
                }
        }
    }
}

struct InspectionBrowser: UIViewRepresentable {
    let plate: String
    let completion: (Result<Deadline, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(plate: plate, completion: completion) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Normal WKWebView environment; no spoofing, CAPTCHA solvers or token injection.
        view.load(URLRequest(url: URL(string: "https://globi.bg/tools/annual-technical-inspection")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.task?.cancel(); view.stopLoading() }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let plate: String
        let completion: (Result<Deadline, Error>) -> Void
        var started = false
        var task: Task<Void, Never>?
        init(plate: String, completion: @escaping (Result<Deadline, Error>) -> Void) { self.plate = plate; self.completion = completion }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { completion(.failure(error)) }
        }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { completion(.failure(error)) }
        }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            guard !started, view.url?.host == "globi.bg" else { return }
            started = true
            task = Task { @MainActor in
                do {
                    guard let url = Bundle.main.url(forResource: "webview-bridge", withExtension: "js") else { throw GarageError.unexpectedResponse }
                    _ = try await view.evaluateJavaScript(try String(contentsOf: url, encoding: .utf8))
                    let submitted = try await view.evaluateJavaScript("window.carDeadlinesBridge.fillAndSubmit('\(plate)')") as? [String: Any]
                    guard submitted?["state"] as? String == "submitted" else { throw GarageError.unexpectedResponse }
                    for _ in 0..<120 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let result = try await view.evaluateJavaScript("window.carDeadlinesBridge.readResult()") as? [String: Any]
                        if result?["state"] as? String == "error" {
                            throw NSError(domain: "Inspection", code: 1, userInfo: [NSLocalizedDescriptionKey: result?["message"] as? String ?? "Справката отказа проверката."])
                        }
                        if result?["state"] as? String == "result", let text = result?["text"] as? String {
                            completion(.success(try Responses.inspection(text, plate: plate)))
                            return
                        }
                    }
                    throw NSError(domain: "Inspection", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не получихме резултат до 2 минути. Опитай отново или въведи датата ръчно."])
                } catch is CancellationError { return }
                catch { completion(.failure(error)) }
            }
        }
    }
}
