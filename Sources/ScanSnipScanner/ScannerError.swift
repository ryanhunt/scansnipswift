import ScanSnipProtocol

/// Why talking to a scanner failed.
public enum ScannerError: Error, Sendable, Equatable {
    /// No answer within the time allowed (the operation is named).
    case timedOut(String)
    /// The scanner closed the connection. It does so, without an answer, to a command sent too long after
    /// its greeting and to control commands sent before registering.
    case connectionClosed(String)
    /// The network refused or dropped the connection. On iOS a refused local-network permission shows up here.
    case network(String)
    /// Discovery got no answer.
    case noAnswer
    /// The scanner is not a model this client can scan with yet (the announced model is given).
    case unsupportedModel(String)
    /// No password was given and none can be derived from the scanner's name.
    case passwordRequired
    /// The scanner refused the registration.
    case registrationRefused(VENS.RegistrationStatus)
    /// A scan is already running on this `WiFiScanner`.
    case alreadyScanning
    /// No sheet was put in before the first-sheet timeout.
    case noSheet
    /// A jam, cover open, double feed or other paper problem.
    case paper(SCSISense)
    /// A scan-channel command failed (the command is named; the sense data, if it could be read).
    case commandFailed(String, SCSISense?)
    /// A scan-channel command answered with a status other than GOOD or CHECK CONDITION.
    case unexpectedStatus(String, UInt32)
    /// The scanner's bytes do not follow the wire format.
    case protocolError(VENSError)
}

/// Runs a wire-format call, turning its `VENSError` into `ScannerError.protocolError`.
func wire<T>(_ body: () throws(VENSError) -> T) throws -> T {
    do {
        return try body()
    } catch {
        throw ScannerError.protocolError(error)
    }
}
