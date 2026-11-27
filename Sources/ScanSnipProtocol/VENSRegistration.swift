import Foundation

extension VENS {
    private static let passwordKey: [UInt8] = Array("pFusCANsNapFiPfu".utf8)
    private static let registrationBodyLength = 96
    private static let scannerTimeout: UInt8 = 0x1E

    /// The password as the registration carries it: for each character, three decimal digits of
    /// `key[i] + character + 11`, with the key `pFusCANsNapFiPfu`. At most 16 characters.
    public static func encodedPassword(_ password: String) throws(VENSError) -> [UInt8] {
        let characters = Array(password.utf8)
        guard characters.count <= passwordKey.count else { throw .passwordTooLong }
        return zip(passwordKey, characters).flatMap { key, character in
            let value = Int(key) + Int(character) + 11
            return [value / 100, value / 10 % 10, value % 10].map { UInt8(ascii: "0") + UInt8($0) }
        }
    }

    /// The host ID ScanSnap Home pairs a Mac under: the Mac's hardware address shifted left 16 bits, as
    /// 8 big-endian bytes. ScanSnap Home takes the address of `en1` (else the first other `en1…`
    /// interface, else `en0`). From thomergil/open-scansnap, which checked it against ScanSnap Home's
    /// stored value. Read the real address with SystemConfiguration: `getifaddrs` reports
    /// 02:00:00:00:00:00 on macOS.
    public static func hostID(mac: [UInt8]) -> [UInt8] {
        precondition(mac.count == 6, "A MAC address is 6 bytes")
        return mac + [0, 0]
    }

    /// Who is registering, which decides how the scanner checks the registration.
    public enum Registrant: Sendable, Equatable {
        /// A computer in the scanner's host table, paired over USB (reserve mode 0): the scanner checks the
        /// host ID and the password. ScanSnap Home on a Mac registers this way.
        case pairedHost(hostID: [UInt8])
        /// The ScanSnap mobile apps' way in (reserve mode 1, host ID zero): the scanner checks only the
        /// password, so no pairing is needed. Checked on the iX100 (firmware 0V00, 2026-11-27); not yet on
        /// the iX500.
        case mobile
    }

    /// The 96-byte body of a registration (control command 0x11), sent on the control channel before
    /// each scan session:
    ///
    /// | Offset | Content |
    /// |---|---|
    /// | 0 | u16 interface version (from discovery), u8 0x1e (scanner timeout) |
    /// | 4 | u32 reserve mode: 0 for a paired host, 1 for a mobile client |
    /// | 8 | u32 1: a password follows |
    /// | 12 | host IPv4 |
    /// | 16 | u32 notification port 55265 |
    /// | 20 | encoded password, 48 bytes of ASCII digits |
    /// | 68 | u16 year, u8 month, day, hour, minute, second (local time) |
    /// | 76 | 8-byte host ID (zero for a mobile client) |
    /// | 84 | i32 time-zone bias in seconds (minus the UTC offset), interface version > 3 only |
    ///
    /// The ScanSnap iOS app pads the body with zeros to 352 bytes (the iX1500's length); the iX100 accepts
    /// both lengths.
    public static func registrationBody(
        interfaceVersion: UInt16, hostIP: [UInt8], password: String, registrant: Registrant, date: Date,
        timeZone: TimeZone
    ) throws(VENSError) -> [UInt8] {
        precondition(hostIP.count == 4, "An IPv4 address is 4 bytes")
        let (reserveMode, hostID): (UInt32, [UInt8]) = switch registrant {
        case .pairedHost(let hostID): (0, hostID)
        case .mobile: (1, [UInt8](repeating: 0, count: 8))
        }
        precondition(hostID.count == 8, "A host ID is 8 bytes")
        var body = [UInt8](repeating: 0, count: registrationBodyLength)
        func put(_ bytes: [UInt8], at offset: Int) { body.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put(bigEndian(interfaceVersion), at: 0)
        body[2] = scannerTimeout
        put(bigEndian(reserveMode), at: 4)
        put(bigEndian(UInt32(1)), at: 8)
        put(hostIP, at: 12)
        put(bigEndian(UInt32(notificationPort)), at: 16)
        put(try encodedPassword(password), at: 20)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        put(bigEndian(UInt16(parts.year ?? 0)), at: 68)
        put([parts.month, parts.day, parts.hour, parts.minute, parts.second].map { UInt8($0 ?? 0) }, at: 70)
        put(hostID, at: 76)
        if interfaceVersion > 3 { put(bigEndian(Int32(-timeZone.secondsFromGMT(for: date))), at: 84) }
        return body
    }

    /// The scanner's answer to a registration (`u32 length | VENS | i32 status | ...`, 20 bytes).
    public enum RegistrationStatus: Sendable, Equatable {
        case accepted
        /// -2: sent without a password.
        case passwordMissing
        /// -3: wrong password. The factory password is the last four characters of the serial number.
        case wrongPassword
        /// -4: in use by another host, over USB or Wi-Fi (for example ScanSnap Home).
        case busy
        /// -6: a paired-host registration that the scanner does not accept from this host. Seen on an
        /// iX100 with no paired computer, for any host ID; register as `Registrant.mobile` instead.
        case notPaired
        /// -7: the host ID is not in the scanner's host table; set up Wi-Fi with ScanSnap Home over USB.
        case unknownHost
        /// A status nobody has observed yet (-1 and -5 exist in ScanSnap Home).
        case other(Int32)

        public init(code: Int32) {
            switch code {
            case 0: self = .accepted
            case -2: self = .passwordMissing
            case -3: self = .wrongPassword
            case -4: self = .busy
            case -6: self = .notPaired
            case -7: self = .unknownHost
            default: self = .other(code)
            }
        }

        public init(reply: [UInt8]) throws(VENSError) {
            guard reply.count >= 20 else { throw .truncated(expected: 20, actual: reply.count) }
            guard Array(reply[4..<8]) == magic else { throw .badMagic }
            self.init(code: Int32(bitPattern: readUInt32(reply, at: 8)))
        }
    }
}
