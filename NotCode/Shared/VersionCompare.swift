import Foundation

enum VersionCompare {
    /// Numeric semver-ish comparison: "1.0.10" > "1.0.9", tolerant of a
    /// leading "v" and different component counts.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "v", with: "", options: [.anchored, .caseInsensitive])
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
