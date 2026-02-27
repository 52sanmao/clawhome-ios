//
//  CLIRelayEncryption.swift
//  contextgo
//
//  Encryption/Decryption for CLI relay sessions.
//  Matches relay-compatible encryption protocol:
//  - Key derivation: HMAC-SHA512 tree (matching deriveKey.ts)
//  - DataEncryptionKey: NaCl box (ephemeral public key + nonce + ciphertext)
//  - Metadata/AgentState: AES-256-GCM (version + nonce + ciphertext + tag)
//

import Foundation
import CryptoKit
import CommonCrypto

class CLIRelayEncryption {
    private let masterSecret: Data
    private var contentKeyPairCandidates: [NaClCrypto.BoxKeyPairCandidate] = []
    private var sessionDataKeys: [String: Data] = [:]  // sessionId -> decrypted 32-byte data key
    private let crypto = NaClCrypto.shared

    init(secret: Data) {
        self.masterSecret = secret
        // Derive the content key pair on init
        deriveContentKeyPair()
    }

    // MARK: - Key Derivation (matches Happy's deriveKey.ts)

    /// Derive compatible content key pair candidates from master secret.
    /// Keep newest candidate first, then historical fallbacks.
    private func deriveContentKeyPair() {
        guard masterSecret.count == 32 else {
            return
        }

        let candidates = crypto.deriveContentKeyPairCandidates(masterSecret: masterSecret)
        contentKeyPairCandidates = candidates

        if let primary = candidates.first {
            print("🔐DEBUG iOS publicKey: \(primary.publicKey.base64EncodedString()) (\(primary.label))")
        } else {
            print("🔐DEBUG Failed to derive keypair candidates")
        }
    }

    /// HMAC-SHA512
    private func hmacSHA512(key: Data, data: Data) -> Data {
        var hmac = Data(count: Int(CC_SHA512_DIGEST_LENGTH))
        hmac.withUnsafeMutableBytes { hmacPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA512),
                        keyPtr.baseAddress, key.count,
                        dataPtr.baseAddress, data.count,
                        hmacPtr.baseAddress
                    )
                }
            }
        }
        return hmac
    }

    // MARK: - Session Key Management

    /// Initialize session encryption by decrypting the session's dataEncryptionKey
    /// The encrypted key format: [version(1)] [ephemeralPubKey(32)] [nonce(24)] [ciphertext]
    func initializeSession(sessionId: String, encryptedDataKeyBase64: String) -> Bool {
        guard !contentKeyPairCandidates.isEmpty else {
            return false
        }

        guard let encryptedData = Data(base64Encoded: encryptedDataKeyBase64) else {
            return false
        }

        guard encryptedData.count > 1, encryptedData[0] == 0 else {
            return false
        }

        let bundle = Data(encryptedData.dropFirst())
        print("🔐DEBUG session \(sessionId.prefix(8)): encrypted \(encryptedData.count)b, bundle \(bundle.count)b")

        var lastError: Error?
        for candidate in contentKeyPairCandidates {
            do {
                let decryptedKey = try crypto.decryptEphemeralBundle(
                    bundle: bundle,
                    recipientSecretKey: candidate.secretKey
                )

                guard decryptedKey.count == 32 else {
                    continue
                }

                sessionDataKeys[sessionId] = decryptedKey

                // Move successful candidate to front to speed up following decrypts.
                if let index = contentKeyPairCandidates.firstIndex(of: candidate), index > 0 {
                    contentKeyPairCandidates.remove(at: index)
                    contentKeyPairCandidates.insert(candidate, at: 0)
                }

                print("🔐DEBUG session \(sessionId.prefix(8)): ✅ SUCCESS (\(candidate.label))")
                return true
            } catch {
                lastError = error
            }
        }

        if let lastError {
            print("🔐DEBUG session \(sessionId.prefix(8)): ❌ FAILED - \(lastError)")
        } else {
            print("🔐DEBUG session \(sessionId.prefix(8)): ❌ FAILED - unable to resolve keypair")
        }
        return false
    }

    /// Initialize encryption key for any resource (session or machine) by id.
    func initializeResource(resourceId: String, encryptedDataKeyBase64: String) -> Bool {
        initializeSession(sessionId: resourceId, encryptedDataKeyBase64: encryptedDataKeyBase64)
    }

    // MARK: - AES-256-GCM Decryption (for metadata, agentState, messages)

    /// Decrypt AES-256-GCM encrypted data
    /// Format: [version(1)] [nonce(12)] [ciphertext] [authTag(16)]
    func decryptAESGCM(data: Data, sessionId: String) throws -> Data {
        guard let dataKey = sessionDataKeys[sessionId] else {
            throw EncryptionError.sessionKeyNotFound
        }

        guard data.count > 1 + 12 + 16 else {
            throw EncryptionError.invalidData
        }

        // Version byte
        guard data[0] == 0 else {
            throw EncryptionError.unsupportedVersion
        }

        let nonce = data[1..<13]                         // 12 bytes
        let ciphertext = data[13..<(data.count - 16)]    // variable
        let tag = data[(data.count - 16)...]             // 16 bytes

        let key = SymmetricKey(data: dataKey)

        // Combine nonce
        let nonceData = try AES.GCM.Nonce(data: nonce)

        // Construct sealed box from nonce + ciphertext + tag
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonceData,
            ciphertext: ciphertext,
            tag: tag
        )

        let plaintext = try AES.GCM.open(sealedBox, using: key)
        return plaintext
    }

    /// Decrypt a base64-encoded encrypted blob and parse as JSON
    func decryptJSON<T: Decodable>(base64String: String, sessionId: String, as type: T.Type) -> T? {
        guard let data = Data(base64Encoded: base64String), !data.isEmpty else {
            return nil
        }

        do {
            let plaintext = try decryptAESGCM(data: data, sessionId: sessionId)
            return try JSONDecoder().decode(type, from: plaintext)
        } catch {
            // Don't spam logs for every failed decryption
            return nil
        }
    }

    /// Decrypt a base64 payload to JSON object. Uses AES-GCM when data key exists, otherwise legacy secretbox.
    func decryptJSONObject(base64String: String, resourceId: String, prefersDataKey: Bool) -> Any? {
        guard let payload = Data(base64Encoded: base64String), !payload.isEmpty else {
            return nil
        }

        do {
            let plaintext: Data
            if prefersDataKey, hasSessionKey(resourceId) {
                plaintext = try decryptAESGCM(data: payload, sessionId: resourceId)
            } else {
                plaintext = try decryptLegacySecretBox(data: payload)
            }
            return try JSONSerialization.jsonObject(with: plaintext)
        } catch {
            return nil
        }
    }

    /// Encrypt JSON object to base64 payload. Uses AES-GCM when data key exists, otherwise legacy secretbox.
    func encryptJSONObject(_ payload: Any, resourceId: String, prefersDataKey: Bool) throws -> String {
        let plaintext = try JSONSerialization.data(withJSONObject: payload)
        let encrypted: Data

        if prefersDataKey, hasSessionKey(resourceId) {
            encrypted = try encryptAESGCM(data: plaintext, sessionId: resourceId)
        } else {
            encrypted = try encryptLegacySecretBox(data: plaintext)
        }

        return encrypted.base64EncodedString()
    }

    /// Encrypt data with AES-256-GCM for a session
    func encryptAESGCM(data: Data, sessionId: String) throws -> Data {
        guard let dataKey = sessionDataKeys[sessionId] else {
            throw EncryptionError.sessionKeyNotFound
        }

        let key = SymmetricKey(data: dataKey)
        let sealedBox = try AES.GCM.seal(data, using: key)

        // Build bundle: [version(1)] [nonce(12)] [ciphertext] [tag(16)]
        var bundle = Data([0x00])
        bundle.append(contentsOf: sealedBox.nonce)
        bundle.append(sealedBox.ciphertext)
        bundle.append(sealedBox.tag)
        return bundle
    }

    // MARK: - Convenience (used by RelayClient)

    /// Old API compatibility - derive session key
    func deriveSessionKey(sessionId: String, dataKey: Data?) -> Bool {
        // If we have an encrypted dataKey, try to initialize
        if let encryptedKey = dataKey {
            let base64 = encryptedKey.base64EncodedString()
            return initializeSession(sessionId: sessionId, encryptedDataKeyBase64: base64)
        }
        return false
    }

    /// Encrypt text for a session
    func encrypt(text: String, sessionId: String) throws -> Data {
        let plaintext = text.data(using: .utf8)!
        return try encryptAESGCM(data: plaintext, sessionId: sessionId)
    }

    /// Decrypt data for a session
    func decrypt(data: Data, sessionId: String) throws -> String {
        let plaintext = try decryptAESGCM(data: data, sessionId: sessionId)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw EncryptionError.invalidUTF8
        }
        return text
    }

    /// Check if a session has been initialized for encryption
    func hasSessionKey(_ sessionId: String) -> Bool {
        return sessionDataKeys[sessionId] != nil
    }

    private func decryptLegacySecretBox(data: Data) throws -> Data {
        guard data.count > NaClCrypto.nonceSize else {
            throw EncryptionError.invalidData
        }

        let nonce = data.prefix(NaClCrypto.nonceSize)
        let ciphertext = data.suffix(from: NaClCrypto.nonceSize)

        do {
            return try crypto.decryptSecretBox(
                encrypted: Data(ciphertext),
                nonce: Data(nonce),
                key: masterSecret
            )
        } catch {
            throw EncryptionError.decryptionFailed
        }
    }

    private func encryptLegacySecretBox(data: Data) throws -> Data {
        do {
            let nonce = try crypto.randomBytes(NaClCrypto.nonceSize)
            let ciphertext = try crypto.encryptSecretBox(
                message: data,
                nonce: nonce,
                key: masterSecret
            )
            var bundle = Data()
            bundle.append(nonce)
            bundle.append(ciphertext)
            return bundle
        } catch {
            throw EncryptionError.encryptionFailed
        }
    }

    // MARK: - Errors

    enum EncryptionError: Error, LocalizedError {
        case sessionKeyNotFound
        case invalidUTF8
        case invalidData
        case unsupportedVersion
        case encryptionFailed
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .sessionKeyNotFound:
                return "Session encryption key not found"
            case .invalidUTF8:
                return "Invalid UTF-8 string"
            case .invalidData:
                return "Invalid encrypted data format"
            case .unsupportedVersion:
                return "Unsupported encryption version"
            case .encryptionFailed:
                return "Encryption failed"
            case .decryptionFailed:
                return "Decryption failed"
            }
        }
    }
}
