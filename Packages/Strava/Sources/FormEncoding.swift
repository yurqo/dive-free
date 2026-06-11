import Foundation

/// `application/x-www-form-urlencoded` body builder, shared by the OAuth token
/// requests and the activity upload. Fields are sorted for deterministic bodies
/// (which keeps them easy to assert in tests).
enum FormEncoding {
    static func body(_ fields: [String: String]) -> Data {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
