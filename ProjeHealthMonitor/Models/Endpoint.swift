import Foundation

struct Endpoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    var expectedStatusCode: Int = 200
    var checkIntervalOverride: TimeInterval?

    /// Dot-path into the JSON response body, e.g. "data.status". Dictionary keys only, no array indices.
    var jsonFieldPath: String?
    /// Expected value at `jsonFieldPath`, compared as a trimmed, case-insensitive string.
    var expectedFieldValue: String?
}
