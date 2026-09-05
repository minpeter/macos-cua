import Foundation

struct CUAError: Error, LocalizedError {
    let message: String
    let code: String
    // Serialized details keep Error's Sendable contract without storing untyped objects.
    let resultJSON: Data?

    init(message: String, code: String = "operation_failed", resultJSON: Data? = nil) {
        self.message = message
        self.code = code
        self.resultJSON = resultJSON
    }

    var errorDescription: String? {
        message
    }
}

@discardableResult
func requireValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw CUAError(message: message)
    }
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseInt(_ raw: String, name: String) throws -> Int {
    guard let value = Int32(raw) else {
        throw CUAError(message: "invalid \(name): \(raw) (expected signed 32-bit integer)", code: "invalid_arguments")
    }
    return Int(value)
}

func parseWindowID(_ raw: String) throws -> Int {
    guard let value = UInt32(raw), value > 0 else {
        throw CUAError(message: "invalid window id: \(raw) (expected integer in 1...4294967295)", code: "invalid_arguments")
    }
    return Int(value)
}

func errorPayload(_ error: Error) throws -> [String: Any] {
    var detail: [String: Any] = [
        "code": (error as? CUAError)?.code ?? "operation_failed",
        "message": error.localizedDescription,
    ]
    if let result = (error as? CUAError)?.resultJSON {
        detail["result"] = try JSONSerialization.jsonObject(with: result)
    }
    return ["error": detail]
}

func reportFailure(_ error: Error, json: Bool) -> Never {
    if json {
        do {
            let data = try JSONSerialization.data(withJSONObject: errorPayload(error), options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fail("failed to serialize error: \(error.localizedDescription)")
        }
        exit(1)
    }
    fail(error.localizedDescription)
}
