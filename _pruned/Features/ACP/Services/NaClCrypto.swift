//
//  NaClCrypto.swift
//  contextgo
//
//  NaCl box encryption for Happy terminal authorization
//  Wraps TweetNaCl for curve25519xsalsa20poly1305 encryption
//  Compatible with the Happy CLI's TweetNaCl implementation
//

import Foundation
import CryptoKit
import TweetNacl

class NaClCrypto {
    static let shared = NaClCrypto()

    // NaCl constants
    static let publicKeySize = 32
    static let secretKeySize = 32
    static let nonceSize = 24

    private init() {}

    struct BoxKeyPairCandidate: Equatable {
        let label: String
        let publicKey: Data
        let secretKey: Data
    }

    // MARK: - Key Pair Generation

    /// Generate a new NaCl box key pair (Curve25519)
    func generateKeyPair() throws -> (publicKey: Data, secretKey: Data) {
        let keyPair = try NaclBox.keyPair()
        return (publicKey: keyPair.publicKey, secretKey: keyPair.secretKey)
    }

    /// Derive public key from secret key
    func publicKeyFromSecretKey(_ secretKey: Data) throws -> Data {
        let keyPair = try NaclBox.keyPair(fromSecretKey: secretKey)
        return keyPair.publicKey
    }

    // MARK: - Ephemeral Key Encryption (App → CLI)

    /// Encrypt a payload for the CLI using an ephemeral key pair
    /// Returns bundle format: [ephemeralPublicKey(32)] [nonce(24)] [encrypted(...)]
    /// This is the format expected by the CLI's decryptWithEphemeralKey()
    func encryptWithEphemeralKey(
        message: Data,
        recipientPublicKey: Data
    ) throws -> Data {
        // 1. Generate ephemeral key pair
        let ephemeralKeyPair = try NaclBox.keyPair()

        // 2. Generate random nonce
        let nonce = try NaclUtil.secureRandomData(count: NaClCrypto.nonceSize)

        // 3. Encrypt using NaCl box
        let encrypted = try NaclBox.box(
            message: message,
            nonce: nonce,
            publicKey: recipientPublicKey,
            secretKey: ephemeralKeyPair.secretKey
        )

        // 4. Build bundle: [ephemeralPublicKey(32)] [nonce(24)] [encrypted(...)]
        var bundle = Data()
        bundle.append(ephemeralKeyPair.publicKey)  // 32 bytes
        bundle.append(nonce)                        // 24 bytes
        bundle.append(encrypted)                    // variable length
        return bundle
    }

    // MARK: - Box Encryption/Decryption

    /// Encrypt using NaCl box
    func encrypt(
        message: Data,
        nonce: Data,
        publicKey: Data,
        secretKey: Data
    ) throws -> Data {
        return try NaclBox.box(
            message: message,
            nonce: nonce,
            publicKey: publicKey,
            secretKey: secretKey
        )
    }

    /// Decrypt using NaCl box.open
    func decrypt(
        encrypted: Data,
        nonce: Data,
        publicKey: Data,
        secretKey: Data
    ) throws -> Data {
        return try NaclBox.open(
            message: encrypted,
            nonce: nonce,
            publicKey: publicKey,
            secretKey: secretKey
        )
    }

    // MARK: - SecretBox Encryption/Decryption

    /// Decrypt using NaCl secretbox.open
    func decryptSecretBox(
        encrypted: Data,
        nonce: Data,
        key: Data
    ) throws -> Data {
        return try NaclSecretBox.open(
            box: encrypted,
            nonce: nonce,
            key: key
        )
    }

    /// Encrypt using NaCl secretbox
    func encryptSecretBox(
        message: Data,
        nonce: Data,
        key: Data
    ) throws -> Data {
        return try NaclSecretBox.secretBox(
            message: message,
            nonce: nonce,
            key: key
        )
    }

    /// Decrypt an ephemeral key bundle
    /// Bundle format: [ephemeralPublicKey(32)] [nonce(24)] [encrypted(...)]
    func decryptEphemeralBundle(
        bundle: Data,
        recipientSecretKey: Data,
        verbose: Bool = false
    ) throws -> Data {
        // Normalize to a fresh Data buffer so indexing is always zero-based.
        // Callers often pass Data.SubSequence (e.g. dropFirst/ suffix), whose
        // indices are offset and would break fixed index slicing below.
        let normalizedBundle = Data(bundle)

        guard normalizedBundle.count > NaClCrypto.publicKeySize + NaClCrypto.nonceSize else {
            throw NaClError.invalidBundle
        }

        let ephemeralPublicKey = normalizedBundle.prefix(NaClCrypto.publicKeySize)
        let nonce = normalizedBundle.subdata(in: NaClCrypto.publicKeySize..<(NaClCrypto.publicKeySize + NaClCrypto.nonceSize))
        let encrypted = normalizedBundle.suffix(from: NaClCrypto.publicKeySize + NaClCrypto.nonceSize)

        if verbose {
            print("🔐DEBUG decrypting:")
            print("  ephPub: \(Data(ephemeralPublicKey).base64EncodedString())")
            print("  nonce: \(nonce.base64EncodedString())")
            print("  encrypted: \(encrypted.count)b")
            print("  recipientSecretKey: \(recipientSecretKey.count)b")
        }

        // Try using box_open with full parameters
        let result = try NaclBox.open(
            message: Data(encrypted),
            nonce: nonce,
            publicKey: Data(ephemeralPublicKey),
            secretKey: recipientSecretKey
        )
        if verbose {
            print("🔐DEBUG ✅ Decryption SUCCESS, result: \(result.count)b")
        }
        return result
    }

    // MARK: - Utilities

    /// Generate random bytes
    func randomBytes(_ count: Int) throws -> Data {
        return try NaclUtil.secureRandomData(count: count)
    }

    // MARK: - Base64 URL-safe encoding/decoding

    /// Encode data as base64 URL-safe string (no padding)
    func encodeBase64URL(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode base64 URL-safe string to data
    func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }

    // MARK: - Ed25519 Signing (for account authentication)

    /// Generate Ed25519 signing key pair from a 32-byte seed
    func signKeyPairFromSeed(_ seed: Data) throws -> (publicKey: Data, secretKey: Data) {
        let keyPair = try NaclSign.KeyPair.keyPair(fromSeed: seed)
        return (publicKey: keyPair.publicKey, secretKey: keyPair.secretKey)
    }

    /// Create a detached Ed25519 signature
    func signDetached(message: Data, secretKey: Data) throws -> Data {
        return try NaclSign.signDetached(message: message, secretKey: secretKey)
    }

    // MARK: - Key Derivation (Happy EnCoder tree)

    /// HMAC-SHA512
    func hmacSHA512(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    /// Derive key tree root: HMAC-SHA512(key = usage + " Master Seed", data = seed)
    /// Returns (key: 32 bytes, chainCode: 32 bytes)
    private func deriveSecretKeyTreeRoot(seed: Data, usage: String) -> (key: Data, chainCode: Data) {
        let hmacKey = Data((usage + " Master Seed").utf8)
        let result = hmacSHA512(key: hmacKey, data: seed)
        return (key: result.prefix(32), chainCode: result.suffix(32))
    }

    /// Derive key tree child: HMAC-SHA512(key = chainCode, data = [0x00] + index)
    /// Returns (key: 32 bytes, chainCode: 32 bytes)
    private func deriveSecretKeyTreeChild(chainCode: Data, index: String) -> (key: Data, chainCode: Data) {
        var data = Data([0x00])
        data.append(Data(index.utf8))
        let result = hmacSHA512(key: chainCode, data: data)
        return (key: result.prefix(32), chainCode: result.suffix(32))
    }

    /// Derive key from master secret using Happy's HMAC-SHA512 tree
    /// Mirrors: deriveKey(masterSecret, usage, path) from Happy's encryption/deriveKey.ts
    func deriveKey(masterSecret: Data, usage: String, path: [String]) -> Data {
        var state = deriveSecretKeyTreeRoot(seed: masterSecret, usage: usage)
        for index in path {
            state = deriveSecretKeyTreeChild(chainCode: state.chainCode, index: index)
        }
        return state.key
    }

    /// Equivalent of libsodium's crypto_box_seed_keypair:
    /// Takes a 32-byte seed, hashes it, clamps, and generates keypair
    func boxKeyPairFromSeed(_ seed: Data) throws -> (publicKey: Data, secretKey: Data) {
        let hash = SHA512.hash(data: seed)
        var secretKey = Data(Data(hash).prefix(32))

        // Clamp the secret key for Curve25519
        secretKey[0] &= 248
        secretKey[31] &= 127
        secretKey[31] |= 64

        // Derive public key from clamped secret key
        let keyPair = try NaclBox.keyPair(fromSecretKey: secretKey)

        return (publicKey: keyPair.publicKey, secretKey: keyPair.secretKey)
    }

    /// Legacy keypair derivation used by earlier clients:
    /// directly treats seed as NaCl secret key input.
    func boxKeyPairFromRawSeed(_ seed: Data) throws -> (publicKey: Data, secretKey: Data) {
        let keyPair = try NaclBox.keyPair(fromSecretKey: seed)
        return (publicKey: keyPair.publicKey, secretKey: keyPair.secretKey)
    }

    /// Build compatibility candidates for content key derivation.
    /// Order is newest first, then historical fallbacks.
    func deriveContentKeyPairCandidates(masterSecret: Data) -> [BoxKeyPairCandidate] {
        let usages = ["Happy EnCoder", "ContextGo EnCoder"]
        var candidates: [BoxKeyPairCandidate] = []
        var seenSecretKeys = Set<String>()

        for usage in usages {
            let seed = deriveKey(masterSecret: masterSecret, usage: usage, path: ["content"])

            if let keyPair = try? boxKeyPairFromSeed(seed) {
                let fingerprint = keyPair.secretKey.base64EncodedString()
                if !seenSecretKeys.contains(fingerprint) {
                    seenSecretKeys.insert(fingerprint)
                    candidates.append(
                        BoxKeyPairCandidate(
                            label: "\(usage):libsodium-seed",
                            publicKey: keyPair.publicKey,
                            secretKey: keyPair.secretKey
                        )
                    )
                }
            }

            if let keyPair = try? boxKeyPairFromRawSeed(seed) {
                let fingerprint = keyPair.secretKey.base64EncodedString()
                if !seenSecretKeys.contains(fingerprint) {
                    seenSecretKeys.insert(fingerprint)
                    candidates.append(
                        BoxKeyPairCandidate(
                            label: "\(usage):raw-seed",
                            publicKey: keyPair.publicKey,
                            secretKey: keyPair.secretKey
                        )
                    )
                }
            }
        }

        return candidates
    }

    /// Derive the content key pair public key from master secret
    /// This is the public key the CLI needs to encrypt dataEncryptionKey
    /// Derivation: masterSecret → HMAC tree("Happy EnCoder", ["content"]) → crypto_box_seed_keypair → publicKey
    func deriveContentPublicKey(masterSecret: Data) throws -> Data {
        let contentDataKey = deriveKey(masterSecret: masterSecret, usage: "Happy EnCoder", path: ["content"])
        let keyPair = try boxKeyPairFromSeed(contentDataKey)
        return keyPair.publicKey
    }

    // MARK: - Errors

    enum NaClError: Error, LocalizedError {
        case invalidBundle
        case invalidPublicKey
        case encryptionFailed
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .invalidBundle:
                return "Invalid encrypted bundle format"
            case .invalidPublicKey:
                return "Invalid public key"
            case .encryptionFailed:
                return "Encryption failed"
            case .decryptionFailed:
                return "Decryption failed"
            }
        }
    }
}
