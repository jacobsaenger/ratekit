import Foundation

enum Fixtures {
    static func url(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }
}
