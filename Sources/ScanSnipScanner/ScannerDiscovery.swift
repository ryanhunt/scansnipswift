import ScanSnipProtocol

/// A scanner that answered discovery, and how this host reaches it.
public struct DiscoveredScanner: Sendable, Equatable {
    /// How a scanner was found.
    public enum Method: Sendable, Equatable {
        /// At an address given by the app (`ScannerDiscovery.find`).
        case address
        /// By a broadcast probe.
        case broadcast
        /// By probing each address on the subnet, where broadcast was refused (iOS without the multicast
        /// entitlement).
        case subnetProbe
    }

    public let announcement: VENS.Announcement
    /// This host's IPv4 address on the route to the scanner; the registration carries it.
    public let localIPv4: [UInt8]
    public let method: Method

    public init(announcement: VENS.Announcement, localIPv4: [UInt8], method: Method = .address) {
        self.announcement = announcement
        self.localIPv4 = localIPv4
        self.method = method
    }

    public var model: ScanSnapModel? { announcement.knownModel }

    /// The scanner's IPv4 address as text, for `NetworkTransport(host:)`.
    public var host: String { announcement.ipAddress.map(String.init).joined(separator: ".") }

    /// What to save to find this scanner again next time (`ScannerDiscovery.locate`).
    public var remembered: RememberedScanner { RememberedScanner(host: host, name: announcement.name) }
}

/// A scanner to look for first: its last address, and its name to recognise it if the address has changed.
/// The name holds the serial number, so keep it on the device; it is not meant for logs.
public struct RememberedScanner: Codable, Sendable, Equatable {
    public var host: String
    public var name: String?

    public init(host: String, name: String? = nil) {
        self.host = host
        self.name = name
    }
}

/// Finds scanners: at a known address (`find`), on the local networks (`BroadcastBrowser`), or both, starting
/// from the one found last time (`locate`).
public enum ScannerDiscovery {
    /// Finds the remembered scanner, or any scanner if there is none to remember. Tries the remembered address
    /// first (for up to `addressTimeout`); if nothing answers there, or another scanner does (the address can
    /// change), it searches the local networks with `browser` and prefers the scanner with the remembered name.
    /// Save the result's `remembered` for next time.
    public static func locate(
        remembered: RememberedScanner?, addressTimeout: Duration = .seconds(4), browseTimeout: Duration = .seconds(6),
        transport: @Sendable (String) -> any VENSTransport = { NetworkTransport(host: $0, connectTimeout: .seconds(4)) },
        browser: any ScannerBrowser = BroadcastBrowser()
    ) async throws -> DiscoveredScanner {
        if let remembered, !remembered.host.isEmpty {
            // The whole attempt is capped, connecting included: a moved scanner's old address has no route,
            // and the connection would otherwise wait out its own timeout first.
            let rememberedTransport = transport(remembered.host)
            let attempt = try? await withTimeout(addressTimeout) {
                try await find(using: rememberedTransport, timeout: addressTimeout)
            }
            if let found = attempt, remembered.name == nil || found.announcement.name == remembered.name {
                return found
            }
            try Task.checkCancellation()
        }
        let wanted = remembered?.name
        let found = try await browser.browse(timeout: browseTimeout) { scanner in
            wanted == nil ? scanner.model != nil : scanner.announcement.name == wanted
        }
        if let match = found.first(where: { $0.announcement.name == wanted }) ?? found.first(where: { $0.model != nil }) {
            return match
        }
        throw ScannerError.noAnswer
    }

    /// Probes the scanner every `interval` until it answers. A sleeping scanner can take several seconds.
    public static func find(using transport: any VENSTransport, timeout: Duration = .seconds(10),
                            interval: Duration = .seconds(1)) async throws -> DiscoveredScanner {
        var socket = try await transport.datagramSocket(port: VENS.discoveryPort)
        let deadline = ContinuousClock.now + timeout
        do {
            while ContinuousClock.now < deadline {
                // The scanner answers a probe without the client's MAC, so none is sent.
                let probe = VENS.probe(hostIP: socket.localIPv4, hostMAC: [UInt8](repeating: 0, count: 6),
                                       replyPort: socket.localPort)
                try? await socket.send(probe)
                do {
                    let wait = min(interval, max(deadline - ContinuousClock.now, .milliseconds(1)))
                    while let reply = try await socket.receive(timeout: wait) {
                        if let announcement = VENS.Announcement(reply) {
                            await socket.close()
                            return DiscoveredScanner(announcement: announcement, localIPv4: socket.localIPv4)
                        }
                    }
                } catch let error as ScannerError {
                    // The socket closed (for example an ICMP "unreachable" while the scanner wakes): open a new
                    // one after the usual pause, rather than probing again into a socket that cannot hear.
                    guard case .connectionClosed = error else { throw error }
                    await socket.close()
                    try await Task.sleep(for: interval)
                    socket = try await transport.datagramSocket(port: VENS.discoveryPort)
                }
                try Task.checkCancellation()
            }
        } catch {
            await socket.close()
            throw error
        }
        await socket.close()
        throw ScannerError.noAnswer
    }
}

/// Runs `operation`, cancelling it and throwing `ScannerError.timedOut` if it takes longer than `timeout`.
func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T)
    async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw ScannerError.timedOut("discovery") }
        return value
    }
}
