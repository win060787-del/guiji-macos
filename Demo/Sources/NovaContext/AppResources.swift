import Foundation
import ContextCore
#if !SWIFT_PACKAGE
extension Bundle { static var module: Bundle { .main } }
#endif

enum ProjectAccessPolicy {
    static let bookmarks = ProjectBookmarks(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NovaContextDemo/Access/bookmarks.json"))
    static func needsBookmark(_ url: URL) -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NovaContextAppStoreBuild") as? Bool == true else { return false }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path != home && !path.hasPrefix(home + "/")
    }
}
