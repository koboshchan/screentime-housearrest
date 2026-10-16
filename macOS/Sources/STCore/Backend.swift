import Foundation
struct Fail: Decodable { var error: String?; var code: String? }

public struct BackendError: Error, LocalizedError, Sendable {
  public var message: String
  public var code: String? = nil
  public var errorDescription: String? { message }
  /// Permission denial may be privacy authorization or ordinary filesystem access.
  public var isPermissionDenied: Bool {
    if code == "permission_denied" { return true }
    let m = message.lowercased()
    return m.contains("operation not permitted") || m.contains("permission denied") || m.contains("not authorized")
  }
}

/// Runs the bundled Python backend. JSON goes in via stdin; pipes drain concurrently; off the main actor.
public struct Backend: Sendable {
  public var scriptURL: URL
  public init(scriptURL: URL) { self.scriptURL = scriptURL }

  public func status() async throws -> SystemStatus { try await run("status", input: Optional<Int>.none) }
  public func read(dayStart: Double, dayEnd: Double) async throws -> ReadResult {
    struct Q: Encodable { var dayStart: Double; var dayEnd: Double }
    return try await run("read", input: Q(dayStart: dayStart, dayEnd: dayEnd))
  }
  public func apply(_ req: ApplyRequest) async throws -> ApplyResult { try await run("apply", input: req) }

  func run<I: Encodable, O: Decodable>(_ command: String, input: I?) async throws -> O {
    // The backend takes the command from the JSON body, not argv.
    var obj: [String: Any] = [:]
    if let input, let raw = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any] { obj = raw }
    obj["command"] = command
    let data = try JSONSerialization.data(withJSONObject: obj)
    let script = scriptURL.path
    let (code, out, err) = try await Task.detached(priority: .userInitiated) {
      try Backend.exec(script: script, command: command, stdin: data)
    }.value
    if code == 0, let f = try? JSONDecoder().decode(Fail.self, from: out), let m = f.error {
      throw BackendError(message: m, code: f.code)   // exit 0 but an error payload
    }
    if code != 0 {
      if let f = try? JSONDecoder().decode(Fail.self, from: out), let m = f.error { throw BackendError(message: m, code: f.code) }
      let t = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw BackendError(message: t.isEmpty ? "Backend exited with code \(code)." : t)
    }
    do { return try JSONDecoder().decode(O.self, from: out) }
    catch { throw BackendError(message: "Unreadable backend response: \(error.localizedDescription)") }
  }

  static func exec(script: String, command: String, stdin: Data) throws -> (Int32, Data, Data) {
    signal(SIGPIPE, SIG_IGN)   // a dead child must surface as an error, not kill the app
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")   // fixed path, no PATH lookup
    p.arguments = [script, command]
    p.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1", "HOME": NSHomeDirectory()]
    let i = Pipe(), o = Pipe(), e = Pipe()
    p.standardInput = i; p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { throw BackendError(message: "Could not start the backend: \(error.localizedDescription)") }
    // Readers start only after a successful launch, so a failed launch cannot leave threads blocked.
    final class Box: @unchecked Sendable { var d = Data() }
    let group = DispatchGroup()
    let ob = Box(), eb = Box()
    for (pipe, box) in [(o, ob), (e, eb)] {
      group.enter()
      DispatchQueue.global().async { box.d = pipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    }
    var writeError: Error?
    do { try i.fileHandleForWriting.write(contentsOf: stdin) } catch { writeError = error }
    try? i.fileHandleForWriting.close()
    p.waitUntilExit()
    group.wait()
    if let writeError, p.terminationStatus == 0 {
      throw BackendError(message: "Could not send the request to the backend: \(writeError.localizedDescription)")
    }
    return (p.terminationStatus, ob.d, eb.d)
  }
}
