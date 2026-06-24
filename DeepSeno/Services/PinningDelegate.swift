import Foundation
import CryptoKit

/// Pins the desktop's self-signed cert by SPKI SHA-256 (UPPER-case colon hex),
/// matching the desktop CertManager.getFingerprint(). Hostname verification is
/// intentionally bypassed: we connect to a VPS IP, not the cert CN — the SPKI
/// pin is what proves we're talking to the right desktop.
/// Conforms to BOTH URLSessionDelegate and URLSessionTaskDelegate. The async
/// streaming API `URLSession.bytes(for:)` (used by SSEClient) delivers its
/// server-trust challenge to the *task-level* method
/// `urlSession(_:task:didReceive:)`. If only the session-level method exists,
/// the challenge falls through to default system trust → the self-signed cert
/// is rejected (-1202 / -9807). `URLSession.data(for:)` (used by APIClient)
/// happens to fall back to the session-level method, which is why APIClient
/// worked while SSEClient did not. Implementing both keeps every transport
/// pinned.
final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let expected: String
    init(fingerprint: String) { self.expected = fingerprint.uppercased() }

    // SecKeyCopyExternalRepresentation returns a PKCS#1 RSAPublicKey (no SPKI
    // wrapper). Desktop hashes the DER SPKI, so we prepend the fixed RSA-2048
    // SPKI ASN.1 header before hashing. VALID ONLY for RSA-2048 keys (the
    // desktop CertManager generates keySize:2048 — if that ever changes, this
    // header must change too). This is the real-device alignment point.
    private static let rsa2048SPKIHeader: [UInt8] = [
        0x30,0x82,0x01,0x22,0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,
        0xf7,0x0d,0x01,0x01,0x01,0x05,0x00,0x03,0x82,0x01,0x0f,0x00
    ]

    /// SPKI SHA-256 (UPPER-case colon hex) of a cert's RSA-2048 public key.
    /// Extracted so it can be unit-tested against the desktop's fingerprint.
    static func fingerprint(for cert: SecCertificate) -> String? {
        guard let pubKey = SecCertificateCopyKey(cert),
              let pkcs1 = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? else {
            return nil
        }
        var spki = Data(rsa2048SPKIHeader); spki.append(pkcs1)
        return SHA256.hash(data: spki).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // Session-level challenge (URLSession.data(for:), .upload(for:), etc.)
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    // Task-level challenge — REQUIRED for URLSession.bytes(for:) (SSE streaming),
    // which never invokes the session-level method above.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // Leaf certificate (iOS 15+ API with fallback)
        let leaf: SecCertificate?
        if #available(iOS 15.0, *) {
            leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            leaf = SecTrustGetCertificateAtIndex(trust, 0)
        }
        guard let cert = leaf, let hex = Self.fingerprint(for: cert) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        if hex == expected {
            // SPKI pin matched. The cert is self-signed, so the default system
            // trust evaluation rejects it with errSSLXCertChainInvalid (-9802) —
            // and handing back URLCredential(trust:) alone is NOT enough, the
            // trust object gets re-evaluated and still fails. Mark this exact
            // trust as an explicit exception so URLSession accepts it.
            SecTrustSetExceptions(trust, SecTrustCopyExceptions(trust))
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            print("[Pinning] mismatch: got \(hex) expected \(expected)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
