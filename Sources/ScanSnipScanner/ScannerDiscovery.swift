import ScanSnipProtocol

/// A scanner that answered discovery, and how this host reaches it.
public struct DiscoveredScanner: Sendable, Equatable {
    public let announcement: VENS.Announcement
    /// This host's IPv4 address on the route to the scanner; the registration carries it.
    public let localIPv4: [UInt8]

    public init(announcement: VENS.Announcement, localIPv4: [UInt8]) {
        self.announcement = announcement
        self.localIPv4 = localIPv4
    }

    public var model: ScanSnapModel? { announcement.knownModel }
}

/// Finds a scanner at a known address with the `VENS` discovery probe.
///
/// Broadcast discovery is not here yet: Network.framework does not send broadcasts, and on iOS they need
/// the multicast entitlement. Ask the user for the scanner's address, or remember the last one.
public enum ScannerDiscovery {
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
                    while let reply = try await socket.receive(timeout: interval) {
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
