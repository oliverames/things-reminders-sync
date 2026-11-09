import Foundation

public enum ThingsCloudError: Error, LocalizedError, Equatable {
    /// The server answered 401: the email/password pair is wrong.
    case invalidCredentials
    /// Any other non-success HTTP status, with the response body.
    case http(Int, String)
    /// A change map failed validation and was never sent.
    case invalidChange([String])
    /// An id (or the account) does not exist.
    case notFound(String)
    /// A server response could not be decoded.
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Things Cloud rejected the email or password."
        case let .http(status, body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Things Cloud returned HTTP \(status)" + (trimmed.isEmpty ? "." : ": \(trimmed.prefix(200))")
        case let .invalidChange(problems):
            return "Refusing to write data Things cannot decode:\n- " + problems.prefix(20).joined(separator: "\n- ")
        case let .notFound(what):
            return "Not found in Things: \(what)."
        case let .decoding(detail):
            return "Could not read the Things Cloud response: \(detail)"
        }
    }
}
