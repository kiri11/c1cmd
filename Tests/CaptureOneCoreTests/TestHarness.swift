import Foundation

public var totalTestCount = 0
public var passedTestCount = 0
public var failedTestCount = 0

public func XCTAssert(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    totalTestCount += 1
    if condition() {
        passedTestCount += 1
    } else {
        failedTestCount += 1
        print("FAIL: [\(file):\(line)] \(message)")
    }
}

public func XCTAssertTrue(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssert(condition(), message.isEmpty ? "Expected true" : message, file: file, line: line)
}

public func XCTAssertFalse(_ condition: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssert(!condition(), message.isEmpty ? "Expected false" : message, file: file, line: line)
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    let valA = a()
    let valB = b()
    XCTAssert(valA == valB, "\(message) (Expected '\(valA)' == '\(valB)')", file: file, line: line)
}

public func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, accuracy: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    let valA = a()
    let valB = b()
    XCTAssert(abs(valA - valB) <= accuracy, "\(message) (Expected '\(valA)' == '\(valB)' within \(accuracy))", file: file, line: line)
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    let valA = a()
    let valB = b()
    XCTAssert(valA != valB, "\(message) (Expected '\(valA)' != '\(valB)')", file: file, line: line)
}

public func XCTAssertNil(_ a: @autoclosure () -> Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssert(a() == nil, "\(message) (Expected nil)", file: file, line: line)
}

public func XCTAssertNotNil(_ a: @autoclosure () -> Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssert(a() != nil, "\(message) (Expected not nil)", file: file, line: line)
}

public func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    totalTestCount += 1
    do {
        _ = try expression()
        passedTestCount += 1
    } catch {
        failedTestCount += 1
        print("FAIL: [\(file):\(line)] Expected no throw, caught \(error) - \(message)")
    }
}

public func XCTAssertNoThrowBlock<T>(_ message: String = "", file: StaticString = #file, line: UInt = #line, _ block: () throws -> T) {
    totalTestCount += 1
    do {
        _ = try block()
        passedTestCount += 1
    } catch {
        failedTestCount += 1
        print("FAIL: [\(file):\(line)] Expected no throw, caught \(error) - \(message)")
    }
}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line, errorHandler: ((Error) -> Void)? = nil) {
    totalTestCount += 1
    do {
        _ = try expression()
        failedTestCount += 1
        print("FAIL: [\(file):\(line)] Expected throw, but expression succeeded - \(message)")
    } catch {
        passedTestCount += 1
        errorHandler?(error)
    }
}

public func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) {
    totalTestCount += 1
    failedTestCount += 1
    print("FAIL: [\(file):\(line)] \(message)")
}
