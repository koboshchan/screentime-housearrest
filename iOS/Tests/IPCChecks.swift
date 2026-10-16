import Foundation

@main struct IPCChecks {
    static func main() {
        let path = CommandLine.arguments[1]
        var checked = 0
        for op in HelperOp.allCases {
            guard let r = HelperClient.runFixture(path: path, op: op),
                  !r.ok, r.code == "auth_unavailable",
                  !Capability.from(r).canApply else { fatalError("IPC denial decode failed for \(op)") }
            checked += 1
        }
        for op in HelperOp.allCases {
            guard let r = HelperClient.runFixture(path: path, op: op, extra: ["unexpected"]),
                  !r.ok, r.code == "bad_request" else { fatalError("Extra argv was not rejected") }
            checked += 1
        }
        guard HelperClient.runFixture(path: "/nonexistent/helper", op: .probe) == nil else {
            fatalError("Missing helper not rejected")
        }
        print("PASS \(checked) actual HelperClient posix_spawn/pipe/waitpid/Swift JSONDecoder IPC cases + missing executable")
    }
}
