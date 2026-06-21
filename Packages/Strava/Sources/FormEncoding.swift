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

/// `multipart/form-data` body builder for the file upload (`POST /v3/uploads`),
/// which can't be form-encoded. Text fields are sorted for deterministic bodies
/// (so tests can assert them); the file part is appended last.
enum MultipartEncoding {
    /// One file part: the field name, the upload filename, its MIME type, and bytes.
    struct FilePart {
        let name: String
        let filename: String
        let contentType: String
        let data: Data
    }

    static func body(fields: [String: String], file: FilePart, boundary: String) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: \(file.contentType)\r\n\r\n")
        body.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
