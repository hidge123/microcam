import CryptoKit
import Foundation

struct CryptoBox: Sendable {
    private let key: SymmetricKey

    static func ephemeral() -> CryptoBox {
        CryptoBox(key: SymmetricKey(size: .bits256))
    }

    static func loadOrCreate() throws -> CryptoBox {
        if let keyData = try KeychainStore.data(for: .databaseKey) {
            return CryptoBox(key: SymmetricKey(data: keyData))
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try KeychainStore.set(keyData, for: .databaseKey)
        return CryptoBox(key: key)
    }

    func seal(_ value: String?) throws -> Data? {
        guard let value else { return nil }
        let sealed = try AES.GCM.seal(Data(value.utf8), using: key)
        guard let combined = sealed.combined else { throw CryptoBoxError.missingCombinedData }
        return combined
    }

    func open(_ data: Data?) throws -> String? {
        guard let data else { return nil }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key)
        guard let value = String(data: plain, encoding: .utf8) else {
            throw CryptoBoxError.invalidText
        }
        return value
    }
}

enum CryptoBoxError: LocalizedError {
    case missingCombinedData
    case invalidText

    var errorDescription: String? {
        switch self {
        case .missingCombinedData: "无法生成加密数据"
        case .invalidText: "解密内容不是有效文本"
        }
    }
}
