import Foundation
import Testing
@testable import Oomph

struct EqtuneBinaryTests {
    /// A downloaded Oomph's engine is quarantined; the copy `install` runs from must not be.
    @Test func installsFromACopyWithoutTheQuarantineFlag() throws {
        let original = FileManager.default.temporaryDirectory.appending(path: "quarantined-eqtune")
        try Data("engine".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let flag = "0081;6ae3f928;Safari;"
        #expect(setxattr(original.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)

        let copy = try EqtuneBinary.unquarantinedCopy(of: original)
        #expect(try Data(contentsOf: copy) == Data("engine".utf8))
        #expect(getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    }
}
