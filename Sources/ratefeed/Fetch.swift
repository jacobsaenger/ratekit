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
func checkLinks(_ urls: Set<URL>, timeout: TimeInterval = 20) -> [URL: LinkCheck] {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout * 2
    let session = URLSession(configuration: config)
    // Linux marks concurrentPerform's closure @Sendable, so the function it calls must be too.
    @Sendable func check(_ url: URL) -> LinkCheck? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: LinkCheck?
        session.dataTask(with: request) { _, response, _ in
            let http = response as? HTTPURLResponse
            result = LinkCheck.classify(original: url, final: http?.url, statusCode: http?.statusCode)
            done.signal()
        }.resume()
        done.wait()
        return result
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
