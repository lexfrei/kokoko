import Foundation

public enum FirmwareStatus: Equatable, Sendable {
    case current
    case behind(latest: String)
    case ahead
}

/// Compares dotted versions number by number, ignoring a `+build` suffix; a
/// missing component counts as 0. Versions that differ and are not all
/// numbers cannot be ordered, so they give nil.
public func firmwareStatus(device: String, published: String) -> FirmwareStatus? {
    let release = withoutBuild(published)
    if !release.isEmpty, withoutBuild(device) == release { return .current }
    guard let mine = versionComponents(device), let theirs = versionComponents(release) else { return nil }
    for index in 0..<max(mine.count, theirs.count) {
        let left = index < mine.count ? mine[index] : 0
        let right = index < theirs.count ? theirs[index] : 0
        if left < right { return .behind(latest: release) }
        if left > right { return .ahead }
    }
    return .current
}

public func firmwareSuffix(_ status: FirmwareStatus?) -> String {
    switch status {
    case .current?: " ✓"
    case .behind(let latest)?: " → \(latest)"
    case .ahead?: " (newer than the published release)"
    case nil: ""
    }
}

private func withoutBuild(_ version: String) -> String {
    version.split(separator: "+", omittingEmptySubsequences: false).first.map(String.init) ?? ""
}

private func versionComponents(_ version: String) -> [Int]? {
    let core = withoutBuild(version)
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { Int($0) }
    guard !core.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
    return numbers
}
