import Combine
import CoreServices
import Foundation

/// Change dots in the sidebar for workspace folders inside a git repository: modified files orange, new files green,
/// folders holding changes grey. Read-only: runs `git status --no-optional-locks` so it never takes the index lock
/// a commit in the terminal might need at the same moment.
///
/// When it runs: only while the sidebar is shown and the workspace has folders. An FSEvents stream per repository
/// reports file changes and commits made elsewhere (terminal, other editors); events are collected for 0.3 s, then
/// one `git status` (20 to 50 ms on a 5000-file repository) runs in the background. No polling.
@MainActor
final class GitStatus: ObservableObject {
    static let shared = GitStatus()

    enum Change { case modified, added }

    /// Absolute path → change, for files.
    @Published private(set) var files: [String: Change] = [:]
    /// Absolute paths of folders that contain a change somewhere below.
    @Published private(set) var folders: Set<String> = []

    /// Workspace folder → its repository root (nil: not in a repository). Looked up once per folder.
    private var repositories: [String: String?] = [:]
    private var streams: [String: FSEventStreamRef] = [:]
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var bag: Set<AnyCancellable> = []

    private init() {
        let settings = AppSettings.shared
        settings.$showSidebar.combineLatest(settings.$workspaceFolders)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show, folders in
                MainActor.assumeIsolated { self?.configure(show: show, folders: folders) }
            }
            .store(in: &bag)
    }

    func change(of url: URL) -> Change? { files[url.standardizedFileURL.path] }
    func hasChanges(in folder: URL) -> Bool { folders.contains(folder.standardizedFileURL.path) }

    /// Called when Nib becomes active or saves: catches anything the event stream could not (e.g. a repository created later).
    func refresh() { schedule(delay: 0) }

    private func configure(show: Bool, folders: [String]) {
        guard show, !folders.isEmpty, Git.executable != nil else {
            stopAll()
            files = [:]
            self.folders = []
            return
        }
        let wanted = Set(folders)
        repositories = repositories.filter { wanted.contains($0.key) }
        schedule(delay: 0)
    }

    private func stopAll() {
        for stream in streams.values {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams = [:]
        pending?.cancel()
    }

    private func schedule(delay: Double) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.run() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func run() {
        let settings = AppSettings.shared
        guard settings.showSidebar, !settings.workspaceFolders.isEmpty else { return }
        generation += 1
        let current = generation
        let folders = settings.workspaceFolders
        let known = repositories
        Task.detached(priority: .utility) {
            var lookup = known
            for folder in folders where lookup[folder] == nil {
                lookup[folder] = .some(Git.repositoryRoot(of: folder))
            }
            let roots = Set(lookup.values.compactMap { $0 })
            var files: [String: Change] = [:]
            for root in roots { files.merge(Git.status(of: root)) { a, _ in a } }
            // Git reports real paths; a workspace folder reached through a symlink lists its files under the link path.
            for folder in folders {
                let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
                guard real != folder else { continue }
                for (path, change) in files where path.hasPrefix(real + "/") {
                    files[folder + path.dropFirst(real.count)] = change
                }
            }
            var parents = Set<String>()
            for path in files.keys {
                var folder = (path as NSString).deletingLastPathComponent
                let tops = roots.union(folders)
                while let root = tops.first(where: { folder == $0 || folder.hasPrefix($0 + "/") }), folder.count >= root.count {
                    guard parents.insert(folder).inserted else { break }
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
            await MainActor.run {
                guard current == self.generation else { return }
                self.repositories = lookup
                self.watch(roots)
                if self.files != files { self.files = files }
                if self.folders != parents { self.folders = parents }
            }
        }
    }

    // MARK: Watching

    private func watch(_ roots: Set<String>) {
        for (root, stream) in streams where !roots.contains(root) {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streams[root] = nil
        }
        for root in roots where streams[root] == nil {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let status = Unmanaged<GitStatus>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { status.events(Array(list.prefix(count))) }
            }
            guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                                   UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
            else { continue }
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
            streams[root] = stream
        }
    }

    /// Changes inside .git matter only for the index, HEAD and refs (commit, checkout, reset); objects and logs are noise.
    private func events(_ paths: [String]) {
        let relevant = paths.contains { path in
            guard let range = path.range(of: "/.git") else { return true }
            let inside = path[range.upperBound...]
            return inside.isEmpty || inside == "/" || inside.hasPrefix("/refs")
        }
        guard relevant else { return }
        schedule(delay: 0.3)
        // The sidebar re-reads its folders too, so files created elsewhere appear without switching apps.
        NotificationCenter.default.post(name: .nibFilesChanged, object: nil)
    }
}

extension Notification.Name {
    static let nibFilesChanged = Notification.Name("NibFilesChanged")
}

/// Runs git without ever triggering the "install command line developer tools" prompt on Macs that lack them.
enum Git {
    static let executable: String? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) { return path }
        // /usr/bin/git is a shim: without Xcode or the command line tools it pops an install dialog. Check first.
        guard let developer = run("/usr/bin/xcode-select", ["-p"]), !developer.isEmpty,
              fm.fileExists(atPath: developer.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return "/usr/bin/git"
    }()

    static func repositoryRoot(of folder: String) -> String? {
        guard let git = executable, let out = run(git, ["-C", folder, "rev-parse", "--show-toplevel"]) else { return nil }
        let root = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : URL(fileURLWithPath: root).standardizedFileURL.path
    }

    static func status(of root: String) -> [String: GitStatus.Change] {
        guard let git = executable,
              let out = run(git, ["--no-optional-locks", "-C", root, "status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"])
        else { return [:] }
        var result: [String: GitStatus.Change] = [:]
        for record in out.split(separator: "\0") where record.count > 3 {
            let x = record[record.startIndex]
            let y = record[record.index(after: record.startIndex)]
            let path = root + "/" + record.dropFirst(3)
            if x == "D" || y == "D" { continue }
            result[path] = (x == "?" || x == "A") ? .added : .modified
        }
        return result
    }

    /// Output on success, nil on failure or after 2 seconds (a huge repository is skipped rather than waited on).
    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
