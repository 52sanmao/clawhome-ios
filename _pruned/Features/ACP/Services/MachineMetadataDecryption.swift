//
//  MachineMetadataDecryption.swift
//  contextgo
//
//  Machine metadata decryption for device registration in Core
//  Fetches machine info from happy-server and decrypts it for Core device registration
//

import Foundation
import CryptoKit
import TweetNacl

/// Machine metadata structure (matches CLI's MachineMetadata)
struct MachineMetadata: Decodable {
    let host: String
    let platform: String
    let osVersion: String
    let arch: String
    let nodeVersion: String
    let shell: String?
    let terminal: String?
    let cpuCount: Int
    let runtimeType: String
    let runtimeServer: String
    let contextgoCliVersion: String
    let homeDir: String
    let contextgoHomeDir: String
    let contextgoLibDir: String
}

/// Machine info from happy-server
struct CLIRelayMachine: Decodable {
    let id: String
    let metadata: String  // base64 encrypted
    let metadataVersion: Int
    let daemonState: String?
    let daemonStateVersion: Int
    let dataEncryptionKey: String?  // base64, optional
    let active: Bool
    let activeAt: Int64
    let createdAt: Int64
    let updatedAt: Int64
}

class MachineMetadataDecryption {
    /// Fetch and decrypt machine metadata from happy-server
    /// - Parameters:
    ///   - machineId: The machine ID
    ///   - serverURL: happy-server base URL
    ///   - token: JWT bearer token for auth
    ///   - secret: 32-byte master secret (from terminal auth)
    /// - Returns: Decrypted machine metadata
    static func fetchAndDecrypt(
        machineId: String,
        serverURL: String,
        token: String,
        secret: Data
    ) async throws -> MachineMetadata {
        // 1. Fetch machine from happy-server
        let machine = try await fetchMachine(machineId: machineId, serverURL: serverURL, token: token)

        // 2. Decrypt metadata
        return try decryptMetadata(machine: machine, secret: secret)
    }

    // MARK: - Private

    private static func fetchMachine(
        machineId: String,
        serverURL: String,
        token: String
    ) async throws -> CLIRelayMachine {
        let baseURL = serverURL.hasSuffix("/") ? serverURL : serverURL + "/"
        guard let url = URL(string: baseURL + "v1/machines/\(machineId)") else {
            throw DecryptionError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DecryptionError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw DecryptionError.httpError(httpResponse.statusCode)
        }

        // Response format: { "machine": { ... } }
        struct MachineResponse: Decodable {
            let machine: CLIRelayMachine
        }

        let decoded = try JSONDecoder().decode(MachineResponse.self, from: data)
        return decoded.machine
    }

    private static func decryptMetadata(
        machine: CLIRelayMachine,
        secret: Data
    ) throws -> MachineMetadata {
        guard secret.count == 32 else {
            throw DecryptionError.invalidSecret
        }

        guard let metadataBundle = Data(base64Encoded: machine.metadata) else {
            throw DecryptionError.invalidBase64
        }

        // Try dataKey mode first (new)
        if let dataKeyBase64 = machine.dataEncryptionKey,
           let encryptedDataKey = Data(base64Encoded: dataKeyBase64) {
            do {
                return try decryptMetadataWithDataKey(
                    metadataBundle: metadataBundle,
                    encryptedDataKey: encryptedDataKey,
                    secret: secret
                )
            } catch {
                // Fall through to legacy mode
                print("[MachineMetadata] DataKey decrypt failed: \(error), trying legacy")
            }
        }

        // Fall back to legacy mode
        return try decryptMetadataLegacy(metadataBundle: metadataBundle, secret: secret)
    }

    /// Decrypt with dataKey mode (AES-256-GCM)
    private static func decryptMetadataWithDataKey(
        metadataBundle: Data,
        encryptedDataKey: Data,
        secret: Data
    ) throws -> MachineMetadata {
        // 1. Derive content key pair from master secret
        let crypto = NaClCrypto.shared
        let contentSeed = crypto.deriveKey(masterSecret: secret, usage: "Happy EnCoder", path: ["content"])
        let contentKeyPair = try crypto.boxKeyPairFromSeed(contentSeed)

        // 2. Decrypt the dataEncryptionKey (NaCl box with ephemeral key)
        // Format: [version(1)] [ephemeralPubKey(32)] [nonce(24)] [ciphertext]
        guard encryptedDataKey.count > 1, encryptedDataKey[0] == 0 else {
            throw DecryptionError.invalidDataKeyFormat
        }

        let bundle = Data(encryptedDataKey.dropFirst())
        let machineDataKey = try crypto.decryptEphemeralBundle(
            bundle: bundle,
            recipientSecretKey: contentKeyPair.secretKey
        )

        guard machineDataKey.count == 32 else {
            throw DecryptionError.invalidDataKeyLength
        }

        // 3. Decrypt metadata with AES-256-GCM
        // Format: [version(1)] [nonce(12)] [ciphertext] [authTag(16)]
        guard metadataBundle.count > 1 + 12 + 16 else {
            throw DecryptionError.invalidMetadataFormat
        }

        guard metadataBundle[0] == 0 else {
            throw DecryptionError.unsupportedVersion
        }

        let nonce = metadataBundle[1..<13]
        let ciphertext = metadataBundle[13..<(metadataBundle.count - 16)]
        let tag = metadataBundle[(metadataBundle.count - 16)...]

        let key = SymmetricKey(data: machineDataKey)
        let nonceData = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonceData, ciphertext: ciphertext, tag: tag)

        let plaintext = try AES.GCM.open(sealedBox, using: key)

        // 4. Parse JSON
        return try JSONDecoder().decode(MachineMetadata.self, from: plaintext)
    }

    /// Decrypt with legacy mode (NaCl secretbox)
    private static func decryptMetadataLegacy(
        metadataBundle: Data,
        secret: Data
    ) throws -> MachineMetadata {
        // Legacy format: [nonce(24)] [ciphertext]
        guard metadataBundle.count > 24 else {
            throw DecryptionError.invalidMetadataFormat
        }

        let nonce = metadataBundle.prefix(24)
        let ciphertext = metadataBundle.suffix(from: 24)

        // Use TweetNaCl secretbox via NaClCrypto wrapper
        let crypto = NaClCrypto.shared
        let plaintext = try crypto.decryptSecretBox(
            encrypted: Data(ciphertext),
            nonce: Data(nonce),
            key: secret
        )

        // Parse JSON
        return try JSONDecoder().decode(MachineMetadata.self, from: plaintext)
    }

    // MARK: - Errors

    enum DecryptionError: Error, LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int)
        case invalidSecret
        case invalidBase64
        case invalidDataKeyFormat
        case invalidDataKeyLength
        case invalidMetadataFormat
        case unsupportedVersion
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid happy-server URL"
            case .invalidResponse:
                return "Invalid server response"
            case .httpError(let code):
                return "HTTP error \(code)"
            case .invalidSecret:
                return "Invalid master secret (must be 32 bytes)"
            case .invalidBase64:
                return "Invalid base64 encoding"
            case .invalidDataKeyFormat:
                return "Invalid dataEncryptionKey format"
            case .invalidDataKeyLength:
                return "Invalid dataEncryptionKey length"
            case .invalidMetadataFormat:
                return "Invalid metadata format"
            case .unsupportedVersion:
                return "Unsupported encryption version"
            case .decryptionFailed:
                return "Decryption failed"
            }
        }
    }
}
