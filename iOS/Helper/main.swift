import Foundation
import Darwin
#if STE_CALLER_AUTH
@_silgen_name("ste_authorize_caller") func authorizeCaller() -> Int32
#endif

func reply(_ result: HelperReply) -> Never {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write((try? encoder.encode(result)) ?? Data("{}".utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(result.ok ? 0 : 2)
}
guard CommandLine.arguments.count == 1 else {
    reply(HelperReply(ok:false,code:"bad_request",message:"This helper accepts one JSON request on stdin, not arguments."))
}
#if STE_CALLER_AUTH
guard authorizeCaller() == 1 && geteuid() == 0 else {
    reply(HelperReply(ok:false,code:"unauthorized",message:"Caller authentication or root access failed."))
}
#else
reply(HelperReply(ok:false,code:"auth_unavailable",message:"This compile-validation build has no pinned caller authentication."))
#endif

#if STE_CALLER_AUTH
do {
    var data = Data(), buffer = [UInt8](repeating:0,count:16384)
    while true {
        let n = Darwin.read(STDIN_FILENO,&buffer,buffer.count)
        if n == 0 { break }
        try requireStorage(n > 0 && data.count+n <= StorageProtocol.maximumRequest,"Request exceeds size limit.","bad_request")
        data.append(contentsOf:buffer[0..<n])
    }
    let request = try JSONDecoder().decode(HelperRequest.self,from:data)
    reply(try StorageProtocol.handle(request,storage:NativeStorage()))
} catch let error as StorageFailure {
    reply(HelperReply(ok:false,code:error.code,message:error.description))
} catch {
    reply(HelperReply(ok:false,code:"bad_request",message:"Request or storage operation failed: \(error)"))
}
#endif
