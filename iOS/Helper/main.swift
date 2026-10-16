import Foundation

// Compile-validation stub only. No privilege escalation, filesystem probes,
// live reads, backups, or writes. Root identity alone is not caller authorization.
func reply(_ result: HelperReply) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write((try? encoder.encode(result)) ?? Data("{}".utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(2)
}
let args = CommandLine.arguments
guard args.count == 2, HelperOp(rawValue: args[1]) != nil else {
    reply(HelperReply(ok: false, code: "bad_request", message: "Expected exactly one known operation."))
}
reply(HelperReply(ok: false, code: "integration_unavailable",
    message: "Live access is disabled. RootHide integration, authenticated caller transport, and consistent backup coordination are not implemented.",
    details: ["read": "disabled", "backup": "disabled", "apply": "disabled", "build": "compile-validation-only"]))
