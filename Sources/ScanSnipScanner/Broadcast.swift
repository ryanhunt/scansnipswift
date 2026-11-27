import Darwin
import Foundation
import ScanSnipProtocol

/// An IPv4 network interface that can reach a scanner on its subnet.
public struct IPv4Interface: Sendable, Equatable {
    public let name: String
    public let address: [UInt8]
    public let netmask: [UInt8]

    public init(name: String, address: [UInt8], netmask: [UInt8]) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }

    /// The subnet's broadcast address.
    public var broadcast: [UInt8] { zip(address, netmask).map { $0 | ~$1 } }

    /// Every other host address on the subnet (not the network, broadcast or own address), for probing one by
    /// one where broadcast is not allowed. Nil for subnets larger than `limit` hosts.
    public func otherHosts(limit: Int = 1022) -> [[UInt8]]? {
        let ip = UInt32(bytes: address), mask = UInt32(bytes: netmask)
        let size = Int(~mask)  // host addresses + broadcast
        guard size >= 2, size - 1 <= limit else { return nil }
        let network = ip & mask
        return (1..<UInt32(size)).map { network | $0 }.filter { $0 != ip }.map(\.bytes)
    }

    /// Interfaces that are up, not loopback, can broadcast, and are not link-local (169.254/16).
    public static func current() -> [IPv4Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [IPv4Interface] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  flags & IFF_BROADCAST != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.pointee.ifa_netmask
            else { continue }
            let ip = ipv4Bytes(address), mask = ipv4Bytes(netmask)
            guard ip[0] != 169 || ip[1] != 254 else { continue }
            found.append(IPv4Interface(name: String(cString: entry.pointee.ifa_name), address: ip, netmask: mask))
        }
        return found
    }

    private static func ipv4Bytes(_ pointer: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr).bytes }
    }
}

extension UInt32 {
    init(bytes: [UInt8]) {
        self = bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    var bytes: [UInt8] { [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)] }
}

/// Finds scanners on the local networks without knowing their addresses.
public protocol ScannerBrowser: Sendable {
    /// Every scanner that answers within `timeout`, or as soon as one satisfies `stopWhen`.
    func browse(timeout: Duration, stopWhen: @escaping @Sendable (DiscoveredScanner) -> Bool) async throws
        -> [DiscoveredScanner]
}

/// Sends the discovery probe to each interface's broadcast address, about once a second, with BSD sockets
/// (Network.framework does not send broadcasts).
///
/// On iOS, broadcast needs the `com.apple.developer.networking.multicast` entitlement, which Apple grants on
/// request. Without it the send fails; with `probeSubnetWhenBroadcastFails` the browser then probes every
/// address on the subnet one by one (unicast needs no entitlement), for subnets up to /22.
public struct BroadcastBrowser: ScannerBrowser {
    public var interval: Duration
    public var probeSubnetWhenBroadcastFails: Bool
    /// Probe each address instead of broadcasting, for networks that drop broadcasts (and for testing).
    public var alwaysProbeSubnet: Bool

    public init(interval: Duration = .seconds(1), probeSubnetWhenBroadcastFails: Bool = true,
                alwaysProbeSubnet: Bool = false) {
        self.interval = interval
        self.probeSubnetWhenBroadcastFails = probeSubnetWhenBroadcastFails
        self.alwaysProbeSubnet = alwaysProbeSubnet
    }

    public func browse(timeout: Duration = .seconds(5),
                       stopWhen: @escaping @Sendable (DiscoveredScanner) -> Bool = { _ in false })
        async throws -> [DiscoveredScanner] {
        let interfaces = IPv4Interface.current()
        guard !interfaces.isEmpty else { throw ScannerError.network("no IPv4 network to search") }
        let stop = LockedBox(false)
        let (interval, sweep, always) = (interval, probeSubnetWhenBroadcastFails, alwaysProbeSubnet)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.run(interfaces: interfaces, timeout: timeout, interval: interval, sweep: sweep,
                                     always: always, stopWhen: stopWhen, stop: stop)
                    })
                }
            }
        } onCancel: {
            stop.value = true
        }
    }

    private static func run(interfaces: [IPv4Interface], timeout: Duration, interval: Duration, sweep: Bool,
                            always: Bool, stopWhen: @Sendable (DiscoveredScanner) -> Bool, stop: LockedBox<Bool>)
        throws -> [DiscoveredScanner] {
        let socket = try ProbeSocket()
        defer { socket.close() }
        var found: [DiscoveredScanner] = []
        var probeSubnet: Set<String> = always ? Set(interfaces.map(\.name)) : []  // where broadcast was refused
        let deadline = ContinuousClock.now + timeout
        var nextRound = ContinuousClock.now
        var sweepsLeft = 2  // probing a whole subnet is a lot of packets: twice is enough to wake a scanner
        while ContinuousClock.now < deadline {
            if stop.value { throw CancellationError() }
            if ContinuousClock.now >= nextRound {
                for interface in interfaces {
                    let probe = VENS.probe(hostIP: interface.address, hostMAC: [UInt8](repeating: 0, count: 6),
                                           replyPort: socket.localPort)
                    if !probeSubnet.contains(interface.name) {
                        let error = socket.send(probe, to: interface.broadcast)
                        if error != 0, sweep, [EHOSTUNREACH, EACCES, EPERM, ENETUNREACH].contains(error) {
                            probeSubnet.insert(interface.name)
                        }
                    }
                    if probeSubnet.contains(interface.name), sweepsLeft > 0, let hosts = interface.otherHosts() {
                        for host in hosts { _ = socket.send(probe, to: host) }
                    }
                }
                if !probeSubnet.isEmpty { sweepsLeft -= 1 }
                nextRound = ContinuousClock.now + interval
            }
            while let (reply, sender) = socket.receive() {
                guard let scanner = Self.accept(reply, from: sender, interfaces: interfaces, probedOneByOne: probeSubnet),
                      !found.contains(where: { $0.announcement.ipAddress == sender })
                else { continue }
                found.append(scanner)
                if stopWhen(scanner) { return found }
            }
            socket.wait(milliseconds: 50)
        }
        return found
    }

    /// A reply worth keeping: nothing authenticates one, so only announcements sent from the address they
    /// name, by a host on one of the searched subnets, count.
    static func accept(_ reply: [UInt8], from sender: [UInt8], interfaces: [IPv4Interface],
                       probedOneByOne: Set<String>) -> DiscoveredScanner? {
        guard let announcement = VENS.Announcement(reply), announcement.ipAddress == sender,
              let interface = interfaces.first(where: { sameSubnet(sender, $0) })
        else { return nil }
        return DiscoveredScanner(announcement: announcement, localIPv4: interface.address,
                                 method: probedOneByOne.contains(interface.name) ? .subnetProbe : .broadcast)
    }

    static func sameSubnet(_ address: [UInt8], _ interface: IPv4Interface) -> Bool {
        UInt32(bytes: address) & UInt32(bytes: interface.netmask)
            == UInt32(bytes: interface.address) & UInt32(bytes: interface.netmask)
    }
}

/// A non-blocking UDP socket allowed to broadcast.
final class ProbeSocket {
    private let fd: Int32
    let localPort: UInt16

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw ScannerError.network("socket: errno \(errno)") }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var any = sockaddr_in()
        any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        any.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &any) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw ScannerError.network("bind: errno \(errno)")
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        fd = descriptor
        localPort = UInt16(bigEndian: local.sin_port)
    }

    /// Sends one datagram to `ip` on the discovery port; returns 0 or the errno.
    func send(_ bytes: [UInt8], to ip: [UInt8]) -> Int32 {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = VENS.discoveryPort.bigEndian
        destination.sin_addr.s_addr = UInt32(bytes: ip).bigEndian
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent < 0 ? errno : 0
    }

    /// The next waiting datagram and its sender, or nil if none is waiting.
    func receive() -> ([UInt8], [UInt8])? {
        var buffer = [UInt8](repeating: 0, count: 512)
        var sender = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &length)
                }
            }
        }
        guard count > 0 else { return nil }
        return (Array(buffer.prefix(count)), UInt32(bigEndian: sender.sin_addr.s_addr).bytes)
    }

    /// Waits until a datagram arrives or `milliseconds` pass.
    func wait(milliseconds: Int32) {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&descriptor, 1, milliseconds)
    }

    func close() {
        Darwin.close(fd)
    }
}
