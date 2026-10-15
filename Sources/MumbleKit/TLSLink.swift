import CryptoKit
import Foundation
import Network
import Security

/// The control channel: TLS over TCP with an optional client certificate. Mumble servers usually present a
/// self-signed certificate, so trust is decided here: the system's trust evaluation, or a certificate whose
/// SHA-256 the user accepted earlier. Anything else is refused and reported with the certificate so the
/// user can accept it and reconnect (trust on first use, as every Mumble client does).
final class TLSLink: @unchecked Sendable {
    enum Event {
        case ready
        case data(Data)
        case untrusted(CertificateInfo)
        case closed(String?)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var untrustedCert: CertificateInfo?

    init(host: String, port: UInt16, identity: SecIdentity?, trustedSHA256: String?, queue: DispatchQueue,
         onEvent: @escaping (Event) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        if let identity, let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        let box = TrustBox()
        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            if hash == trustedSHA256?.lowercased() || SecTrustEvaluateWithError(trust, nil) {
                complete(true)
            } else {
                let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "unknown"
                box.cert = CertificateInfo(sha256: hash, subject: subject, der: der)
                complete(false)
            }
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = NWParameters(tls: tls, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        trustBox = box
    }

    private let trustBox: TrustBox

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onEvent(.ready)
                receive()
            case let .failed(error):
                if let cert = trustBox.cert {
                    onEvent(.untrusted(cert))
                } else {
                    onEvent(.closed(error.localizedDescription))
                }
            case let .waiting(error):
                if let cert = trustBox.cert {
                    onEvent(.untrusted(cert))
                    connection.cancel()
                } else {
                    // No usable path yet (radio switching, network coming up): Network.framework retries by
                    // itself. Give up only if it is still not ready after a while.
                    queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, connection.state != .ready, connection.state != .cancelled else { return }
                        onEvent(.closed(error.localizedDescription))
                        connection.cancel()
                    }
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.onEvent(.closed(error.localizedDescription)) }
        })
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { onEvent(.data(data)) }
            if let error {
                onEvent(.closed(error.localizedDescription))
            } else if isComplete {
                onEvent(.closed("The server closed the connection"))
            } else {
                receive()
            }
        }
    }
}

private final class TrustBox: @unchecked Sendable {
    var cert: CertificateInfo?
}

/// Loads a PKCS#12 client identity with an empty password.
func loadIdentity(pkcs12: Data) -> SecIdentity? {
    var items: CFArray?
    let status = SecPKCS12Import(pkcs12 as CFData, [kSecImportExportPassphrase as String: ""] as CFDictionary, &items)
    guard status == errSecSuccess, let array = items as? [[String: Any]], let first = array.first,
          let identity = first[kSecImportItemIdentity as String] else { return nil }
    return (identity as! SecIdentity)
}
