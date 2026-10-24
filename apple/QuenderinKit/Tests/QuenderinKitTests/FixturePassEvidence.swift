import Foundation

/// Keep each CI evidence marker intact alongside XCTest's stderr output.
func emitFixturePass(_ marker: String) {
    let bytes = Data(("\n" + marker + "\n").utf8)
    precondition(bytes.count <= 512 && !marker.contains("\n") && !marker.contains("\r"), "Fixture PASS marker must fit one line and one bounded write")
    FileHandle.standardError.write(bytes)
}
