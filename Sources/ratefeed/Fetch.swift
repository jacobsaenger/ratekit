import Foundation
import RateKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36"
let powerToChooseExport = URL(string: "https://www.powertochoose.org/en-us/Plan/ExportToCsv")!

/// Downloads `url` synchronously. Returns nil on any network or HTTP error.
func download(_ url: URL, timeout: TimeInterval = 40) -> Data? {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Data? = nil
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { result = data }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return result
}

/// Label links in the export sometimes contain raw spaces.
func labelURL(_ string: String) -> URL? {
    if let url = URL(string: string) { return url }
    return string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
}

/// A stable file name for a URL (FNV-1a, 64-bit), so cached labels survive between runs.
func cacheKey(_ string: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(hash, radix: 16)
}

/// `pdftotext -layout`, the same extractor on macOS and Linux.
func pdfText(_ file: URL) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["pdftotext", "-layout", "-enc", "UTF-8", file.path, "-"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Checks every sign-up link, eight at a time: where it ends up after redirects and with
/// what status. A link that looks broken is tried once more a few seconds later, so a
/// passing outage doesn't flag it. Links that time out or block automated checks are left
/// unjudged.
///
/// Each check runs the curl tool: FoundationNetworking's URLSession crashes on Linux with
/// checks in parallel (libcurl error 43 in EasyHandle, 2026-10-24).
func checkLinks(_ urls: Set<URL>, timeout: TimeInterval = 20) -> [URL: LinkCheck] {
    @Sendable func check(_ url: URL) -> LinkCheck? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["curl", "-s", "-o", "/dev/null", "-L", "-b", "", "--max-redirs", "10",
                             "--connect-timeout", "\(Int(timeout))", "--max-time", "\(Int(timeout * 2))",
                             "-A", browserUserAgent, "-w", "%{http_code} %{url_effective}", url.absoluteString]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // "000" when nothing answered. `-b ""` keeps cookies across redirects, as a browser
        // does: some sign-up pages set a session cookie and send visitors without it home.
        let parts = output.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let code = Int(parts[0]), code > 0 else {
            return LinkCheck.classify(original: url, final: nil, statusCode: nil)
        }
        return LinkCheck.classify(original: url, final: URL(string: String(parts[1])), statusCode: code)
    }
    let queue = DispatchQueue(label: "links")
    nonisolated(unsafe) var results: [URL: LinkCheck] = [:]
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
        for (i, url) in urls.sorted(by: { $0.absoluteString < $1.absoluteString }).enumerated() where i % 8 == worker {
            var result = check(url)
            if result?.status == .broken {
                Thread.sleep(forTimeInterval: 5)
                result = check(url)
            }
            if let result { queue.sync { results[url] = result } }
        }
    }
    return results
}

/// Each provider's six months of PUCT complaints by type, from Power to Choose's complaint
/// history pages, keyed by the export's provider name. The page needs the provider's
/// company code, which only the plans API gives: one API call per area maps names to codes.
/// Providers whose page can't be read are left out.
func fetchComplaints(providers: Set<String>) -> [String: ComplaintHistory] {
    func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).uppercased() }
    var codes: [String: (company: String, plan: Int)] = [:]
    for tdu in TDU.allCases where tdu != .oncorNTU {
        guard let zip = ZIPTable.bundled.zips.filter({ $0.value == [tdu] }).keys.sorted().first,
              let url = URL(string: "https://api.powertochoose.org/api/PowerToChoose/plans?zip_code=\(zip)"),
              let data = download(url, timeout: 60),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { continue }
        for row in rows {
            guard let name = row["company_name"] as? String, let company = row["company_id"] as? String,
                  let plan = row["plan_id"] as? Int, codes[key(name)] == nil else { continue }
            codes[key(name)] = (company, plan)
        }
    }
    var byCompany: [String: ComplaintHistory] = [:]
    var out: [String: ComplaintHistory] = [:]
    for provider in providers.sorted() {
        guard let code = codes[key(provider)] else { continue }
        if byCompany[code.company] == nil {
            Thread.sleep(forTimeInterval: 0.5)
            guard let url = URL(string: "https://www.powertochoose.org/en-us/Content/Scores/\(code.plan)?c=\(code.company)"),
                  let data = download(url), let html = String(data: data, encoding: .utf8),
                  let history = ComplaintHistory.parse(html: html) else { continue }
            byCompany[code.company] = history
        }
        out[provider] = byCompany[code.company]
    }
    return out
}
