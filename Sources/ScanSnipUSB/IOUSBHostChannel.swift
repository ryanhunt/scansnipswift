#if os(macOS)
import Foundation
import IOKit
import IOUSBHost
import ScanSnipProtocol
import ScanSnipScanner

/// A ScanSnap on USB, through Apple's IOUSBHost framework (no libusb, no driver). macOS only; iPadOS would need
/// DriverKit.
///
/// The scanner's one interface is vendor-specific with a bulk OUT and a bulk IN endpoint (on the iX100, `0x02`
/// and `0x81`) and no driver attached, so an ordinary process can open it. Transfers block, so they run on a
/// serial queue of the channel's own, never on Swift's cooperative threads.
public final class IOUSBHostChannel: SCSIChannel, @unchecked Sendable {
    private let interface: IOUSBHostInterface
    private let bulkIn: IOUSBHostPipe
    private let bulkOut: IOUSBHostPipe
    private let queue = DispatchQueue(label: "scansnip.usb")
    private let closed = LockedFlag()

    /// The product IDs of ScanSnaps connected now (vendor `FujitsuUSB.vendorID`).
    public static func connectedProductIDs() -> [UInt16] {
        interfaces().map(\.productID)
    }

    /// Opens the first connected ScanSnap with one of `productIDs` (any Fujitsu device if empty).
    public static func open(productIDs: [UInt16] = ScanSnapModel.all.flatMap(\.usbProductIDs)) throws -> IOUSBHostChannel {
        var found = interfaces()
        defer { for candidate in found { IOObjectRelease(candidate.service) } }
        guard let index = found.firstIndex(where: { productIDs.isEmpty || productIDs.contains($0.productID) }) else {
            throw ScannerError.network("no ScanSnap on USB")
        }
        let service = found.remove(at: index).service
        defer { IOObjectRelease(service) }
        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw ScannerError.network("cannot open the USB interface: \(error.localizedDescription)")
        }
        var bulkIn: IOUSBHostPipe?, bulkOut: IOUSBHostPipe?
        for address in Array(0x01...0x0F) + Array(0x81...0x8F) {
            guard let pipe = try? interface.copyPipe(withAddress: address) else { continue }
            if address & 0x80 != 0 { bulkIn = bulkIn ?? pipe } else { bulkOut = bulkOut ?? pipe }
        }
        guard let bulkIn, let bulkOut else {
            interface.destroy()
            throw ScannerError.network("the USB interface has no bulk endpoints")
        }
        // Clear any halt a process that stopped mid-command left on an endpoint. (An iX100 left stuck by an
        // aborted run, every transfer timing out, needed turning off and on; this did not recover it.)
        try? bulkOut.clearStall()
        try? bulkIn.clearStall()
        return IOUSBHostChannel(interface: interface, bulkIn: bulkIn, bulkOut: bulkOut)
    }

    private init(interface: IOUSBHostInterface, bulkIn: IOUSBHostPipe, bulkOut: IOUSBHostPipe) {
        self.interface = interface
        self.bulkIn = bulkIn
        self.bulkOut = bulkOut
    }

    deinit {
        if !closed.value { interface.destroy() }
    }

    public func run(_ cdb: [UInt8], output: [UInt8], inputLength: Int, timeout: Duration) async throws -> SCSIResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try runBlocking(cdb, output: output, inputLength: inputLength,
                                                                   timeout: timeout.timeInterval) })
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !closed.value {
                    closed.value = true
                    interface.destroy()
                }
                continuation.resume()
            }
        }
    }

    // MARK: Blocking transfers (on `queue`)

    private func runBlocking(_ cdb: [UInt8], output: [UInt8], inputLength: Int, timeout: TimeInterval) throws -> SCSIResult {
        guard !closed.value else { throw ScannerError.connectionClosed("USB channel closed") }
        try write(FujitsuUSB.commandBlock(cdb), timeout: timeout)
        if !output.isEmpty { try write(output, timeout: timeout) }
        var data: [UInt8] = []
        if inputLength > 0 {
            do {
                data = try read(inputLength, timeout: timeout)
            } catch {
                // A failed data phase may still be followed by a status packet saying why (as Scan handles).
                if let packet = try? read(FujitsuUSB.statusPacketLength, timeout: 3),
                   let status = FujitsuUSB.StatusPacket(packet), !status.isGood {
                    return SCSIResult(data: [], status: status)
                }
                throw error
            }
        }
        let packet = try read(FujitsuUSB.statusPacketLength, timeout: timeout)
        guard let status = FujitsuUSB.StatusPacket(packet) else {
            throw ScannerError.protocolError(.truncated(expected: FujitsuUSB.statusPacketLength, actual: packet.count))
        }
        return SCSIResult(data: data, status: status)
    }

    private func write(_ bytes: [UInt8], timeout: TimeInterval) throws {
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var sent = 0
        do {
            try bulkOut.__sendIORequest(with: data, bytesTransferred: &sent, completionTimeout: timeout)
        } catch {
            try? bulkOut.clearStall()
            throw ScannerError.network("USB write: \(error.localizedDescription) (\(String(format: "0x%08x", UInt32(truncatingIfNeeded: (error as NSError).code))))")
        }
        guard sent == bytes.count else { throw ScannerError.network("USB write: sent \(sent) of \(bytes.count) bytes") }
    }

    private func read(_ length: Int, timeout: TimeInterval) throws -> [UInt8] {
        guard let data = NSMutableData(length: length) else { throw ScannerError.network("out of memory") }
        var received = 0
        do {
            try bulkIn.__sendIORequest(with: data, bytesTransferred: &received, completionTimeout: timeout)
        } catch {
            try? bulkIn.clearStall()
            throw ScannerError.network("USB read: \(error.localizedDescription) (\(String(format: "0x%08x", UInt32(truncatingIfNeeded: (error as NSError).code))))")
        }
        return Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: UInt8.self), count: received))
    }

    // MARK: Finding the device

    private struct Candidate {
        let service: io_service_t
        let productID: UInt16
    }

    /// Every IOUSBHostInterface from Fujitsu/PFU. Walking the registry found the iX100 where IOUSBHost's own
    /// matching dictionary matched nothing (macOS 27.2.1).
    private static func interfaces() -> [Candidate] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Candidate] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            func number(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int
            }
            if number("idVendor") == Int(FujitsuUSB.vendorID), let product = number("idProduct") {
                found.append(Candidate(service: service, productID: UInt16(truncatingIfNeeded: product)))
            } else {
                IOObjectRelease(service)
            }
        }
        return found
    }
}

/// A Boolean behind a lock.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
