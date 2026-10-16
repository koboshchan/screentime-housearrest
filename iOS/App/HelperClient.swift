import Foundation
import Darwin

/// Spawns the bundled stehelper directly, sends one JSON HelperRequest on stdin, reads one JSON HelperReply.
/// No sockets, no shell, no arguments. Returns nil if the helper cannot run or replies malformed.
/// Privilege transport (how stehelper gets root and authenticates this caller) is the helper/packaging contract;
/// the helper refuses unauthenticated callers itself.
enum HelperClient {
    static let maxReply = 8 * 1024 * 1024

    static var helperPath: String? {
        let p = Bundle.main.bundlePath + "/stehelper"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
    static func run(_ request: HelperRequest) -> HelperReply? {
        guard let path = helperPath else { return nil }
        return execute(path: path, request: request, extra: [])
    }
    static func run(_ op: HelperOp) -> HelperReply? { run(HelperRequest(op: op)) }

    #if HOST_IPC_TEST
    // Host fixture path injection is excluded from the shipping build.
    static func runFixture(path: String, request: HelperRequest, extra: [String] = []) -> HelperReply? {
        execute(path: path, request: request, extra: extra)
    }
    static func runFixture(path: String, op: HelperOp, extra: [String] = []) -> HelperReply? {
        execute(path: path, request: HelperRequest(op: op), extra: extra)
    }
    #endif

    private static func execute(path: String, request: HelperRequest, extra: [String]) -> HelperReply? {
        guard let body = try? JSONEncoder().encode(request), body.count <= 4 * 1024 * 1024 else { return nil }
        var inFds: [Int32] = [0, 0], outFds: [Int32] = [0, 0]
        guard pipe(&inFds) == 0 else { return nil }
        guard pipe(&outFds) == 0 else { close(inFds[0]); close(inFds[1]); return nil }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, inFds[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outFds[1], 1)
        for fd in inFds + outFds { posix_spawn_file_actions_addclose(&fa, fd) }
        let argv = [path] + extra
        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) }; posix_spawn_file_actions_destroy(&fa) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, nil, cargs, environ)
        close(inFds[0]); close(outFds[1])
        guard rc == 0 else { close(inFds[1]); close(outFds[0]); return nil }
        // Write on another thread so a full pipe in either direction cannot deadlock.
        let writeFd = inFds[1]
        DispatchQueue.global().async {
            signal(SIGPIPE, SIG_IGN)
            body.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(writeFd, raw.baseAddress!.advanced(by: off), raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(writeFd)
        }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 16384)
        var overflow = false
        while true {
            let n = read(outFds[0], &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.count > maxReply { overflow = true; break }
        }
        close(outFds[0])
        if overflow { kill(pid, SIGKILL) }
        var st: Int32 = 0; waitpid(pid, &st, 0)
        // Accept documented success/denial exits only: 0 = ok, 2 = refusal. Never signal exits.
        guard !overflow, st == 0 || st == (2 << 8),
              let result = try? JSONDecoder().decode(HelperReply.self, from: data),
              result.ok == (st == 0) else { return nil }
        return result
    }
}
