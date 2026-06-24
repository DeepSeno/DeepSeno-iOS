import Foundation
import CryptoKit

/// ECDH P-256 key agreement + AES-256-GCM encryption.
/// Mirrors Android RelayCrypto.kt and desktop relay-crypto.ts.
///
/// Frame layout (binary):
///   [4 bytes: BE uint32 length] [12 bytes: nonce] [ciphertext + 16B GCM tag]
enum RelayCrypto {

    // MARK: - Key Generation

    /// Generate an ECDH P-256 key pair. Returns (private key, SPKI DER public key base64).
    static func generateKeyPair() throws -> (privateKey: P256.KeyAgreement.PrivateKey, publicKeyBase64: String) {
        let priv = P256.KeyAgreement.PrivateKey()
        let pub = priv.publicKey.derRepresentation.base64EncodedString()
        return (priv, pub)
    }

    /// Derive AES-256 key via ECDH + HKDF-SHA256. Returns raw key bytes.
    static func deriveSharedKey(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKeyBase64: String,
        nonceBase64: String
    ) throws -> Data {
        guard let peerPubData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw RelayError.invalidKey
        }
        let peerPub = try P256.KeyAgreement.PublicKey(derRepresentation: peerPubData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPub)
        guard let nonce = Data(base64Encoded: nonceBase64) else {
            throw RelayError.invalidNonce
        }
        let info = "deepseno-relay-v1".data(using: .utf8)!
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: nonce, sharedInfo: info, outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Derive AES-256 key from LAN bearer token. Returns raw key bytes.
    static func deriveLanKey(token: String) -> Data {
        let ikm = SymmetricKey(data: token.data(using: .utf8)!)
        let salt = "deepseno-lan-v1".data(using: .utf8)!
        let info = "deepseno-lan-proxy".data(using: .utf8)!
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func toKey(_ data: Data) -> SymmetricKey {
        SymmetricKey(data: data)
    }

    // MARK: - Frame Encryption / Decryption

    private static let nonceSize = 12

    /// Encrypt a single plaintext chunk into a frame (4B len + nonce + ciphertext + tag).
    static func encryptFrame(aesKey: Data, plaintext: Data) throws -> Data {
        let key = toKey(aesKey)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        var frame = Data()
        var totalLen = UInt32(nonceSize + sealed.ciphertext.count + sealed.tag.count).bigEndian
        frame.append(Data(bytes: &totalLen, count: 4))
        frame.append(Data(nonce))
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        return frame
    }

    /// Decrypt a single frame.
    static func decryptFrame(aesKey: Data, frame: Data) throws -> Data {
        let key = toKey(aesKey)
        guard frame.count >= 4 + nonceSize + 16 else { throw RelayError.frameTooShort }
        let frameLen = Int(frame.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard frame.count >= 4 + frameLen else { throw RelayError.frameIncomplete }

        let nonce = frame.subdata(in: 4..<(4 + nonceSize))
        let sealed = frame.subdata(in: (4 + nonceSize)..<(4 + frameLen))

        let nonceBox = try AES.GCM.Nonce(data: nonce)
        let box = try AES.GCM.SealedBox(nonce: nonceBox, ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key)
    }

    // MARK: - Request / Response Encryption

    static func encryptRequest(
        aesKey: Data, method: String, path: String, headers: [String: String], body: Data?,
        chunkSize: Int = 1_048_576
    ) throws -> [Data] {
        var frames = [Data]()
        let headerData = try JSONSerialization.data(withJSONObject: [
            "method": method, "path": path, "headers": headers,
        ])
        frames.append(try encryptFrame(aesKey: aesKey, plaintext: headerData))
        if let body, !body.isEmpty {
            var offset = 0
            while offset < body.count {
                let end = min(offset + chunkSize, body.count)
                frames.append(try encryptFrame(aesKey: aesKey, plaintext: body.subdata(in: offset..<end)))
                offset = end
            }
        }
        return frames
    }

    static func encryptResponse(
        aesKey: Data, status: Int, headers: [String: String], body: Data?,
        chunkSize: Int = 1_048_576
    ) throws -> [Data] {
        var frames = [Data]()
        let headerData = try JSONSerialization.data(withJSONObject: [
            "status": status, "headers": headers,
        ])
        frames.append(try encryptFrame(aesKey: aesKey, plaintext: headerData))
        if let body, !body.isEmpty {
            var offset = 0
            while offset < body.count {
                let end = min(offset + chunkSize, body.count)
                frames.append(try encryptFrame(aesKey: aesKey, plaintext: body.subdata(in: offset..<end)))
                offset = end
            }
        }
        return frames
    }

    struct DecryptedRequest {
        let method: String; let path: String; let headers: [String: String]; let body: Data?
    }

    static func decryptRequest(aesKey: Data, frames: [Data]) throws -> DecryptedRequest {
        guard !frames.isEmpty else { throw RelayError.noFrames }
        let headerJson = try decryptFrame(aesKey: aesKey, frame: frames[0])
        let json = try JSONSerialization.jsonObject(with: headerJson) as? [String: Any] ?? [:]
        let method = json["method"] as? String ?? "GET"
        let path = json["path"] as? String ?? "/"
        let headers = json["headers"] as? [String: String] ?? [:]
        var body: Data?
        if frames.count > 1 {
            body = concat(frames.dropFirst().map { try! decryptFrame(aesKey: aesKey, frame: $0) })
        }
        return DecryptedRequest(method: method, path: path, headers: headers, body: body)
    }

    struct DecryptedResponse {
        let status: Int; let headers: [String: String]; let body: Data?
    }

    static func decryptResponse(aesKey: Data, frames: [Data]) throws -> DecryptedResponse {
        guard !frames.isEmpty else { throw RelayError.noFrames }
        let headerJson = try decryptFrame(aesKey: aesKey, frame: frames[0])
        let json = try JSONSerialization.jsonObject(with: headerJson) as? [String: Any] ?? [:]
        let status = json["status"] as? Int ?? 200
        let headers = json["headers"] as? [String: String] ?? [:]
        var body: Data?
        if frames.count > 1 {
            body = concat(frames.dropFirst().map { try! decryptFrame(aesKey: aesKey, frame: $0) })
        }
        return DecryptedResponse(status: status, headers: headers, body: body)
    }

    static func concat(_ arrays: [Data]) -> Data {
        var result = Data()
        for a in arrays { result.append(a) }
        return result
    }
}

enum RelayError: Error {
    case invalidKey, invalidNonce, keyAgreementFailed, cryptoFailed
    case frameTooShort, frameIncomplete, noFrames
}
