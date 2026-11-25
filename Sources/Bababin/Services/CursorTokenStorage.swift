import CommonCrypto
import Foundation
import Security

/// Cursor 3.27+ stores `cursorAuth/accessToken` sealed with Electron safeStorage.
/// The cell is `cursor-safe-storage:v1:` plus base64 of a Chromium `v10` ciphertext.
/// The key is the existing login-keychain item `Cursor Safe Storage` / `Cursor Key`.
enum CursorTokenStorage {
    static let sealedPrefix = "cursor-safe-storage:v1:"
    private static let keychainService = "Cursor Safe Storage"
    private static let keychainAccount = "Cursor Key"

    static func resolve(_ stored: String?) -> Result<String, UsageError> {
        guard let stored, !stored.isEmpty else { return .failure(.noToken) }
        guard stored.hasPrefix(sealedPrefix) else { return .success(stored) }
        guard let password = safeStoragePassword(),
              let token = unwrap(stored, password: password),
              !token.isEmpty else {
            return .failure(.sessionLocked)
        }
        return .success(token)
    }

    static func unwrap(_ stored: String, password: String) -> String? {
        guard stored.hasPrefix(sealedPrefix) else { return stored }
        let encoded = String(stored.dropFirst(sealedPrefix.count))
        guard let encrypted = Data(base64Encoded: encoded),
              encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8) else {
            return nil
        }
        guard let plain = decryptV10(Data(encrypted.dropFirst(3)), password: password),
              let token = String(data: plain, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    static func seal(_ plaintext: String, password: String) -> String? {
        guard let cipher = encryptV10(Data(plaintext.utf8), password: password) else { return nil }
        var payload = Data("v10".utf8)
        payload.append(cipher)
        return sealedPrefix + payload.base64EncodedString()
    }

    private static func safeStoragePassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }
        return password
    }

    private static func derivedKey(_ password: String) -> Data? {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: 16)
        let status = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        16
                    )
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private static func decryptV10(_ ciphertext: Data, password: String) -> Data? {
        guard let key = derivedKey(password) else { return nil }
        return crypt(ciphertext, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func encryptV10(_ plaintext: Data, password: String) -> Data? {
        guard let key = derivedKey(password) else { return nil }
        return crypt(plaintext, key: key, operation: CCOperation(kCCEncrypt))
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let outputCount = input.count + kCCBlockSizeAES128
        var output = Data(count: outputCount)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }
}
