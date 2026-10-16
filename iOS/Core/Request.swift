import Foundation

public struct HelperRequest: Codable {
    public var op: HelperOp
    public var backupID: String?
    public var apply: ApplyRequest?
    public init(op: HelperOp, backupID: String? = nil, apply: ApplyRequest? = nil) {
        self.op = op; self.backupID = backupID; self.apply = apply
    }
}
public enum StorageProtocol {
    public static let maximumRequest = 4 * 1024 * 1024
    public static func handle(_ request: HelperRequest, storage: NativeStorage) throws -> HelperReply {
        switch request.op {
        case .probe:
            _ = try storage.readSnapshot()
            return HelperReply(ok:true,code:"ready",message:"Protected storage is readable and the native writer is available.",details:["root":"1","schema":"supported","protocol":"native-v1","authenticated":"1","writer":"original_local_native"])
        case .read:
            let snapshot = try storage.readSnapshot()
            let encoded = try JSONEncoder().encode(snapshot)
            guard let json = String(data:encoded,encoding:.utf8) else { throw StorageFailure("read_failed","Cannot encode usage.") }
            return HelperReply(ok:true,code:"ok",message:"Loaded existing usage.",details:["snapshot":json])
        case .backup:
            return HelperReply(ok:true,code:"ok",message:"Current backup created and verified.",details:["backupID":try storage.backup()])
        case .verifyBackup:
            guard let id = request.backupID else { throw StorageFailure("invalid_input","Backup identifier required.") }
            return HelperReply(ok:true,code:"ok",message:"Backup verified.",details:["revision":try storage.verifyBackup(id)])
        case .apply:
            guard let edit = request.apply else { throw StorageFailure("invalid_input","Edit required.") }
            return try storage.apply(edit)
        }
    }
}
