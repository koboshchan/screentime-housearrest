import Foundation
import Darwin

/// Spawns the bundled helper directly. No sockets, no shell. Returns nil if it cannot run.
enum HelperClient {
    static var helperPath: String? {
        let p = Bundle.main.bundlePath + "/stehelper"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    static func run(_ op: HelperOp, extra: [String] = []) -> HelperReply? {
        guard let path = helperPath else { return nil }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_addclose(&fa, fds[0])
        let argv = [path, op.rawValue] + extra
        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) }; posix_spawn_file_actions_destroy(&fa) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, nil, cargs, environ)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); return nil }
        // Drain before waiting to avoid pipe deadlock.
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fds[0], &buf, buf.count); if n <= 0 { break }; data.append(buf, count: n); if data.count > 65_536 { break } }
        close(fds[0])
        var st: Int32 = 0; waitpid(pid, &st, 0)
        return try? JSONDecoder().decode(HelperReply.self, from: data)
    }
}
