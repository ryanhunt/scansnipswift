import Foundation
import Testing
import ScanSnipProtocol
@testable import ScanSnipScanner

/// A browser that returns given scanners and counts its calls.
private final class FakeBrowser: ScannerBrowser, @unchecked Sendable {
    let scanners: [DiscoveredScanner]
    private let lock = NSLock()
    private var count = 0

    init(_ scanners: [DiscoveredScanner]) {
        self.scanners = scanners
    }

    private func recordCall() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func browse(timeout: Duration, stopWhen: @escaping @Sendable (DiscoveredScanner) -> Bool) async throws
        -> [DiscoveredScanner] {
        recordCall()
        var found: [DiscoveredScanner] = []
        for scanner in scanners {
            found.append(scanner)
            if stopWhen(scanner) { break }
        }
        return found
    }
}

private func announcement(ip: [UInt8], model: String = "ScanSnap iX100", serial: String = "A0XX012345") -> VENS.Announcement {
    var reply = [UInt8](repeating: 0, count: 132)
    reply.replaceSubrange(0..<4, with: VENS.magic)
    reply.replaceSubrange(8..<12, with: [0, 6, 0, 0x30])
    reply.replaceSubrange(16..<20, with: ip)
    let name = Array("\(model.split(separator: " ").last ?? "")-\(serial)".utf8)
    reply.replaceSubrange(40..<(40 + name.count), with: name)
    reply.replaceSubrange(104..<(104 + model.utf8.count), with: Array(model.utf8))
    return VENS.Announcement(reply)!
}

private func broadcastFound(ip: [UInt8], serial: String = "A0XX012345") -> DiscoveredScanner {
    DiscoveredScanner(announcement: announcement(ip: ip, serial: serial), localIPv4: [192, 0, 2, 10], method: .broadcast)
}

@Suite struct InterfaceTests {
    let lan = IPv4Interface(name: "en0", address: [192, 0, 2, 10], netmask: [255, 255, 255, 0])

    @Test func broadcastAddress() {
        #expect(lan.broadcast == [192, 0, 2, 255])
        #expect(IPv4Interface(name: "en1", address: [10, 1, 2, 3], netmask: [255, 255, 252, 0]).broadcast
            == [10, 1, 3, 255])
    }

    @Test func otherHostsOnTheSubnet() throws {
        let hosts = try #require(lan.otherHosts())
        #expect(hosts.count == 253)  // .1 to .254, without our own .10
        #expect(hosts.first == [192, 0, 2, 1] && hosts.last == [192, 0, 2, 254])
        #expect(!hosts.contains([192, 0, 2, 10]) && !hosts.contains([192, 0, 2, 0]) && !hosts.contains([192, 0, 2, 255]))
        let slash22 = try #require(IPv4Interface(name: "en1", address: [10, 1, 2, 3], netmask: [255, 255, 252, 0]).otherHosts())
        #expect(slash22.count == 1021)
        #expect(IPv4Interface(name: "en1", address: [10, 1, 2, 3], netmask: [255, 255, 0, 0]).otherHosts() == nil)
        #expect(IPv4Interface(name: "p2p", address: [10, 0, 0, 1], netmask: [255, 255, 255, 252]).otherHosts()
            == [[10, 0, 0, 2]])
    }

    @Test func repliesMustComeFromTheAddressTheyAnnounce() throws {
        #expect(BroadcastBrowser.accept([0x56, 0x45], from: [192, 0, 2, 20], interfaces: [lan], probedOneByOne: []) == nil)
        var bytes = [UInt8](repeating: 0, count: 132)
        bytes.replaceSubrange(0..<4, with: VENS.magic)
        bytes.replaceSubrange(16..<20, with: [192, 0, 2, 20])
        let found = try #require(BroadcastBrowser.accept(bytes, from: [192, 0, 2, 20], interfaces: [lan],
                                                         probedOneByOne: []))
        #expect(found.localIPv4 == [192, 0, 2, 10])
        #expect(found.method == .broadcast)
        #expect(found.host == "192.0.2.20")
        #expect(BroadcastBrowser.accept(bytes, from: [192, 0, 2, 20], interfaces: [lan], probedOneByOne: ["en0"])?
            .method == .subnetProbe)
        // Another host claiming the scanner's address, or a host off our subnets, is ignored.
        #expect(BroadcastBrowser.accept(bytes, from: [192, 0, 2, 66], interfaces: [lan], probedOneByOne: []) == nil)
        bytes.replaceSubrange(16..<20, with: [198, 51, 100, 7])
        #expect(BroadcastBrowser.accept(bytes, from: [198, 51, 100, 7], interfaces: [lan], probedOneByOne: []) == nil)
    }
}

@Suite struct LocateTests {
    @Test func theRememberedAddressIsTriedFirst() async throws {
        let scanner = SimulatedScanner()
        let browser = FakeBrowser([broadcastFound(ip: [192, 0, 2, 99])])
        let found = try await ScannerDiscovery.locate(
            remembered: RememberedScanner(host: "192.0.2.20", name: "iX100-A0XX012345"),
            addressTimeout: .milliseconds(300), transport: { _ in SimulatedTransport(scanner: scanner) },
            browser: browser)
        #expect(found.method == .address)
        #expect(found.host == "192.0.2.20")
        #expect(browser.calls == 0)
    }

    @Test func aSilentAddressFallsBackToSearching() async throws {
        let scanner = SimulatedScanner()
        await scanner.setSilent(true)
        let moved = broadcastFound(ip: [192, 0, 2, 31])
        let browser = FakeBrowser([moved])
        let found = try await ScannerDiscovery.locate(
            remembered: RememberedScanner(host: "192.0.2.20", name: "iX100-A0XX012345"),
            addressTimeout: .milliseconds(200), transport: { _ in SimulatedTransport(scanner: scanner) },
            browser: browser)
        #expect(found == moved)
        #expect(found.remembered == RememberedScanner(host: "192.0.2.31", name: "iX100-A0XX012345"))
        #expect(browser.calls == 1)
    }

    @Test func anAddressThatNeverConnectsStillFallsBackInTime() async throws {
        // A moved scanner's old address has no route: connecting waits until cancelled.
        struct NeverConnects: VENSTransport {
            func connect(port: UInt16) async throws -> any VENSStream {
                try await Task.sleep(for: .seconds(60))
                throw ScannerError.timedOut("connect")
            }
            func datagramSocket(port: UInt16) async throws -> any VENSDatagramSocket {
                try await Task.sleep(for: .seconds(60))
                throw ScannerError.timedOut("connect")
            }
        }
        let moved = broadcastFound(ip: [192, 0, 2, 31])
        let start = ContinuousClock.now
        let found = try await ScannerDiscovery.locate(
            remembered: RememberedScanner(host: "192.0.2.20", name: "iX100-A0XX012345"),
            addressTimeout: .milliseconds(200), transport: { _ in NeverConnects() }, browser: FakeBrowser([moved]))
        #expect(found == moved)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func anotherScannerAtTheAddressIsNotTakenForTheRememberedOne() async throws {
        // The address was given to someone else's scanner: search, and prefer the remembered name.
        let scanner = SimulatedScanner()
        await scanner.setSerial("A0XX099999")
        let other = broadcastFound(ip: [192, 0, 2, 40], serial: "A0XX055555")
        let mine = broadcastFound(ip: [192, 0, 2, 41])
        let browser = FakeBrowser([other, mine])
        let found = try await ScannerDiscovery.locate(
            remembered: RememberedScanner(host: "192.0.2.20", name: "iX100-A0XX012345"),
            addressTimeout: .milliseconds(300), transport: { _ in SimulatedTransport(scanner: scanner) },
            browser: browser)
        #expect(found == mine)
    }

    @Test func withNothingRememberedTheFirstKnownModelIsTaken() async throws {
        let unknown = DiscoveredScanner(announcement: announcement(ip: [192, 0, 2, 50], model: "ScanSnap iX1600"),
                                        localIPv4: [192, 0, 2, 10], method: .broadcast)
        let ix100 = broadcastFound(ip: [192, 0, 2, 51])
        let browser = FakeBrowser([unknown, ix100])
        let found = try await ScannerDiscovery.locate(remembered: nil, browser: browser)
        #expect(found == ix100)
    }

    @Test func nothingFoundIsNoAnswer() async throws {
        await #expect(throws: ScannerError.noAnswer) {
            try await ScannerDiscovery.locate(remembered: nil, browser: FakeBrowser([]))
        }
    }

    @Test func rememberedScannersSurviveCoding() throws {
        let remembered = RememberedScanner(host: "192.0.2.20", name: "iX100-A0XX012345")
        let decoded = try JSONDecoder().decode(RememberedScanner.self, from: JSONEncoder().encode(remembered))
        #expect(decoded == remembered)
    }
}
