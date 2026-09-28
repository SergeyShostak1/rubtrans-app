import SwiftUI
import WebKit
import CryptoKit
import Network

let siteHost = "rubtrans.ru"
let appScheme = "rubtrans-app"

// MARK: - Хранилище на диске
enum Store {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("site")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func key(_ u: URL) -> String {
        SHA256.hash(data: Data(u.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func save(_ u: URL, _ data: Data, _ mime: String) {
        let k = key(u)
        try? data.write(to: dir.appendingPathComponent(k + ".d"))
        try? mime.write(to: dir.appendingPathComponent(k + ".m"), atomically: true, encoding: .utf8)
    }
    static func load(_ u: URL) -> (Data, String)? {
        let k = key(u)
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(k + ".d")) else { return nil }
        let m = (try? String(contentsOf: dir.appendingPathComponent(k + ".m"), encoding: .utf8)) ?? "application/octet-stream"
        return (d, m)
    }
}

// MARK: - Сеть
var offlineUntil = Date.distantPast   // если сеть недоступна, не ждём таймаутов

func fetch(_ url: URL, timeout: TimeInterval = 6) async -> (Data, String)? {
    if Date() < offlineUntil { return nil }
    var r = URLRequest(url: url)
    r.timeoutInterval = timeout
    r.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (d, resp) = try? await URLSession.shared.data(for: r),
          let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
        offlineUntil = Date().addingTimeInterval(20)
        return nil
    }
    let mime = h.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
    Store.save(url, d, mime)
    return (d, mime)
}

func realURL(_ u: URL) -> URL {
    var c = URLComponents(url: u, resolvingAgainstBaseURL: false)!
    c.scheme = "https"; c.fragment = nil
    return c.url!
}

func rewrite(_ data: Data, _ mime: String) -> Data {
    let m = mime.lowercased()
    guard m.contains("html") || m.contains("css") || m.contains("javascript") || m.contains("json"),
          var s = String(data: data, encoding: .utf8) else { return data }
    s = s.replacingOccurrences(of: #"(https?:)?//(www\.)?rubtrans\.ru"#,
                               with: "\(appScheme)://\(siteHost)", options: .regularExpression)
    return Data(s.utf8)
}

// MARK: - Обработчик схемы
final class Handler: NSObject, WKURLSchemeHandler {
    static let shared = Handler()
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let u = task.request.url else { return }
        let real = realURL(u)
        let id = ObjectIdentifier(task as AnyObject)
        Task { @MainActor in
            var res = await fetch(real)
            if res == nil { res = Store.load(real) }
            if self.stopped.remove(id) != nil { return }
            if let (d, mime) = res {
                let body = rewrite(d, mime)
                let resp = HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])!
                task.didReceive(resp); task.didReceive(body); task.didFinish()
            } else {
                let resp = HTTPURLResponse(url: u, statusCode: 404, httpVersion: nil, headerFields: nil)!
                task.didReceive(resp); task.didFinish()
            }
        }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task as AnyObject))
    }
}

// MARK: - Краулер (обход всего сайта)
enum Crawler {
    static func run() async {
        let start = URL(string: "https://\(siteHost)/")!
        var seen: Set<String> = [start.absoluteString]
        var queue = [start]
        let pattern = try! NSRegularExpression(
            pattern: #"(?:href|src)\s*=\s*["']([^"'#]+)|url\(\s*["']?([^"')]+)"#, options: [.caseInsensitive])

        while !queue.isEmpty && seen.count < 3000 {
            let batch = Array(queue.prefix(6)); queue.removeFirst(batch.count)
            await withTaskGroup(of: (URL, Data, String)?.self) { g in
                for u in batch {
                    g.addTask { await fetch(u, timeout: 20).map { (u, $0.0, $0.1) } }
                }
                for await r in g {
                    guard let (base, data, mime) = r else { continue }
                    let m = mime.lowercased()
                    guard m.contains("html") || m.contains("css"),
                          let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251)
                    else { continue }
                    let ns = s as NSString
                    for match in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                        let r = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                        let link = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                        guard var url = URL(string: link, relativeTo: base)?.absoluteURL else { continue }
                        guard ["http", "https"].contains(url.scheme ?? ""),
                              let h = url.host, h == siteHost || h == "www." + siteHost else { continue }
                        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                        c.scheme = "https"; c.host = siteHost; c.fragment = nil
                        url = c.url!
                        if seen.insert(url.absoluteString).inserted { queue.append(url) }
                    }
                }
            }
        }
    }

    // запускаем только не по мобильной сети
    static func startIfWiFi() {
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { path in
            mon.cancel()
            if path.status == .satisfied && !path.isExpensive {
                Task.detached { await run() }
            }
        }
        mon.start(queue: .global())
    }
}

// MARK: - UI
@main
struct RubTransApp: App {
    init() { Crawler.startIfWiFi() }
    var body: some Scene { WindowGroup { WebContainer() } }
}

struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(Handler.shared, forURLScheme: appScheme)
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.allowsBackForwardNavigationGestures = true
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: URL(string: "\(appScheme)://\(siteHost)/")!))
        return w
    }
    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        // внешние ссылки открываем в Safari
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = a.request.url, ["http", "https"].contains(u.scheme ?? "") {
                UIApplication.shared.open(u); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}
