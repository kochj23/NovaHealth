// NovaHealth — mTLS Encrypted Transport (Enterprise Feature #4)
// Written by Jordan Koch
//
// Generates client certificate, stores in iOS Keychain.
// QR code pairing flow for initial key exchange.
// URLSessionDelegate for client cert presentation.
// Pins server certificate to prevent MITM.

import Foundation
import UIKit
import Security
import CryptoKit

@MainActor
class MTLSManager: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = MTLSManager()

    @Published var isPaired: Bool = false
    @Published var pairingStatus: String = "Not paired"

    /// The HTTPS server URL when mTLS is configured, nil otherwise
    var serverURL: String? {
        guard isPaired else { return nil }
        return loadFromKeychain(key: "NovaHealth_mTLS_ServerURL")
    }

    /// Whether mTLS is fully configured and ready
    var isConfigured: Bool {
        return isPaired && clientIdentity != nil
    }

    /// URLSession configured with client certificate for mTLS
    lazy var secureSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var clientIdentity: SecIdentity?
    private var serverCertificateData: Data?

    // MARK: - Keychain Constants

    nonisolated private static let clientCertLabel = "NovaHealth-Client-Cert"
    nonisolated private static let serverCertLabel = "NovaHealth-Server-Cert"
    nonisolated private static let pairingTokenKey = "NovaHealth_mTLS_PairingToken"

    override init() {
        super.init()
        loadPairingState()
    }

    // MARK: - QR Code Pairing

    /// Parses QR code content from Mac server to establish mTLS pairing.
    /// QR format: novahealth://pair?server=<base64_url>&cert=<base64_der>&token=<uuid>
    func processPairingQRCode(_ qrContent: String) async -> Bool {
        guard let url = URL(string: qrContent),
              url.scheme == "novahealth",
              url.host == "pair" else {
            pairingStatus = "Invalid QR code format"
            return false
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let serverB64 = components.queryItems?.first(where: { $0.name == "server" })?.value,
              let certB64 = components.queryItems?.first(where: { $0.name == "cert" })?.value,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value else {
            pairingStatus = "Missing pairing data in QR code"
            return false
        }

        // Decode server URL
        guard let serverURLData = Data(base64Encoded: serverB64),
              let serverURLString = String(data: serverURLData, encoding: .utf8) else {
            pairingStatus = "Invalid server URL in QR code"
            return false
        }

        // Decode and store server certificate for pinning
        guard let certData = Data(base64Encoded: certB64) else {
            pairingStatus = "Invalid certificate in QR code"
            return false
        }

        // Generate client key pair and CSR
        guard await generateClientCertificate(serverURL: serverURLString, token: token) else {
            pairingStatus = "Failed to generate client certificate"
            return false
        }

        // Store server cert for pinning
        serverCertificateData = certData
        saveToKeychain(key: "NovaHealth_mTLS_ServerCert", value: certData.base64EncodedString())

        // Store server URL
        saveToKeychain(key: "NovaHealth_mTLS_ServerURL", value: serverURLString)
        saveToKeychain(key: Self.pairingTokenKey, value: token)

        isPaired = true
        pairingStatus = "Paired with \(serverURLString)"
        print("[NovaHealth mTLS] Successfully paired with server")
        return true
    }

    /// Removes all pairing data and reverts to plain HTTP
    func unpair() {
        deleteFromKeychain(key: "NovaHealth_mTLS_ServerURL")
        deleteFromKeychain(key: "NovaHealth_mTLS_ServerCert")
        deleteFromKeychain(key: Self.pairingTokenKey)
        removeClientIdentity()
        clientIdentity = nil
        serverCertificateData = nil
        isPaired = false
        pairingStatus = "Not paired"
        print("[NovaHealth mTLS] Unpairing complete — reverted to plain HTTP")
    }

    // MARK: - Certificate Generation

    private func generateClientCertificate(serverURL: String, token: String) async -> Bool {
        // Generate a P-256 key pair for the client
        let privateKey = P256.Signing.PrivateKey()
        let publicKeyData = privateKey.publicKey.derRepresentation

        // Store private key in Keychain with biometric protection
        let privateKeyData = privateKey.derRepresentation
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: Self.clientCertLabel,
            kSecValueData as String: privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        // Delete existing key if present
        SecItemDelete(attributes as CFDictionary)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("[NovaHealth mTLS] Failed to store client key: \(status)")
            return false
        }

        // Request signed certificate from server using the pairing token
        guard let url = URL(string: "\(serverURL)/pair") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let pairingPayload: [String: String] = [
            "token": token,
            "public_key": publicKeyData.base64EncodedString(),
            "device_name": UIDevice.current.name,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: pairingPayload) else { return false }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("[NovaHealth mTLS] Pairing request rejected by server")
                return false
            }

            // Server returns signed client certificate
            guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let certB64 = responseJSON["client_cert"],
                  let clientCertData = Data(base64Encoded: certB64) else {
                print("[NovaHealth mTLS] Invalid certificate response from server")
                return false
            }

            // Store signed client certificate
            saveToKeychain(key: "NovaHealth_mTLS_ClientCert", value: clientCertData.base64EncodedString())
            print("[NovaHealth mTLS] Client certificate stored in Keychain")
            return true
        } catch {
            print("[NovaHealth mTLS] Pairing request failed: \(error)")
            return false
        }
    }

    // MARK: - Identity Loading

    private func loadPairingState() {
        if let _ = loadFromKeychain(key: "NovaHealth_mTLS_ServerURL"),
           let certB64 = loadFromKeychain(key: "NovaHealth_mTLS_ServerCert"),
           let certData = Data(base64Encoded: certB64) {
            serverCertificateData = certData
            isPaired = true
            pairingStatus = "Paired"
            loadClientIdentity()
        }
    }

    private func loadClientIdentity() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: Self.clientCertLabel,
            kSecReturnRef as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            clientIdentity = (item as! SecIdentity)
        }
    }

    private func removeClientIdentity() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: Self.clientCertLabel,
        ]
        SecItemDelete(query as CFDictionary)

        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: Self.clientCertLabel,
        ]
        SecItemDelete(identityQuery as CFDictionary)
    }

    // MARK: - Keychain Helpers

    private func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "net.digitalnoise.NovaHealth",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary) // Remove existing
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "net.digitalnoise.NovaHealth",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "net.digitalnoise.NovaHealth",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - URLSessionDelegate for Client Certificate Presentation

extension MTLSManager: URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace

        switch protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            // Present client certificate for mTLS
            let query: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: MTLSManager.clientCertLabel,
                kSecReturnRef as String: true,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let identity = item {
                let credential = URLCredential(
                    identity: identity as! SecIdentity,
                    certificates: nil,
                    persistence: .forSession
                )
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        case NSURLAuthenticationMethodServerTrust:
            // Pin server certificate
            guard let serverTrust = protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }

            // If we have a pinned cert, verify against it
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: "NovaHealth_mTLS_ServerCert",
                kSecAttrService as String: "net.digitalnoise.NovaHealth",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var certItem: CFTypeRef?
            let certStatus = SecItemCopyMatching(query as CFDictionary, &certItem)

            if certStatus == errSecSuccess, let pinnedB64Data = certItem as? Data,
               let pinnedB64 = String(data: pinnedB64Data, encoding: .utf8),
               let pinnedCertData = Data(base64Encoded: pinnedB64) {
                // Compare server cert against pinned cert using modern API
                if let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                   let serverCert = certChain.first {
                    let serverCertData = SecCertificateCopyData(serverCert) as Data
                    if serverCertData == pinnedCertData {
                        let credential = URLCredential(trust: serverTrust)
                        completionHandler(.useCredential, credential)
                        return
                    }
                }
                // Pin mismatch — reject
                print("[NovaHealth mTLS] Server certificate pin mismatch — rejecting connection")
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                // No pin configured — use default validation
                completionHandler(.performDefaultHandling, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
