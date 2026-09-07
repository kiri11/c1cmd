import Foundation
import CaptureOneCore

struct WorkingReferenceTests {
    static func run() {
        print("Running WorkingReferenceTests...")
        let ref = WorkingRef()
        XCTAssertTrue(ref.rawValue.hasPrefix("c1_wrk_"))
        XCTAssertTrue(WorkingRef.isWorkingRefString(ref.rawValue))

        XCTAssertFalse(WorkingRef.isWorkingRefString("1"))
        XCTAssertFalse(WorkingRef.isWorkingRefString("66"))
        XCTAssertFalse(WorkingRef.isWorkingRefString("variant-1"))
        XCTAssertNil(WorkingRef(string: "1"))
    }
}
