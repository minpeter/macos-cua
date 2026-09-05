import AppKit
import XCTest
@testable import macos_cua

final class CLIRegressionTests: XCTestCase {
    func testSignedIntegerBounds() throws {
        XCTAssertEqual(try parseInt("2147483647", name: "x"), 2_147_483_647)
        XCTAssertEqual(try parseInt("-2147483648", name: "x"), -2_147_483_648)
        for raw in ["2147483648", "-2147483649", "9223372036854775808", "1.5", ""] {
            XCTAssertThrowsError(try parseInt(raw, name: "x"), raw)
        }
    }

    func testRepeatedPointerFlagsRejected() {
        for flags in [["--fast", "--fast"], ["--precise", "--precise"], ["--fast", "--precise"], ["--screen", "--screen"], ["--unknown"]] {
            XCTAssertThrowsError(try CLI.parsePointerProfile(["1", "2"] + flags, usage: "test"), "\(flags)")
        }
    }

    func testRepeatedClickFlagsRejected() {
        for flags in [["--fast", "--fast"], ["--precise", "--precise"], ["--fast", "--precise"], ["--screen", "--screen"], ["--post-crop", "a.png", "--post-crop", "b.png"], ["--unknown"]] {
            XCTAssertThrowsError(try CLI.parseClickOptions(["1", "2"] + flags, usage: "test"), "\(flags)")
        }
    }

    func testScreenshotRejectsUnknownFlagsAndInvalidRegions() {
        for args in [["--unknown", "a.png"], ["--region", "0", "0", "0", "10", "a.png"], ["--region", "0", "0", "10", "-1", "a.png"]] {
            XCTAssertThrowsError(try CLI.parseScreenshotOptions(args), "\(args)")
        }
    }

    func testInvalidInvocationsNeverReachRecorder() {
        let previous = Recorder.environment
        defer { Recorder.environment = previous }
        var recorderEntered = false
        Recorder.environment.baseDirectory = {
            recorderEntered = true
            throw CUAError(message: "recorder sentinel")
        }
        let invalid = [
            ["--json", "--json", "wait", "0"],
            ["--relative", "--relative", "wait", "0"],
            ["doctor", "extra"], ["state", "extra"],
            ["cursor-position", "extra"], ["screen-size", "extra"],
            ["wait", "-1"], ["wait", "20001"], ["wait", "0", "extra"],
            ["scroll", "2147483648", "0"],
            ["clipboard", "get", "extra"], ["clipboard", "copy", "extra"],
            ["clipboard", "paste", "extra"], ["app", "list", "extra"],
            ["window", "list", "extra"], ["app", "activate", "one", "two"],
            ["onboard", "--no-open", "--no-open"],
            ["onboard", "--wait", "--no-wait"],
            ["type", "--fast", "--fast", "text"],
            ["screenshot", "--screen", "a.png", "window"],
            ["click", "1", "2", "--post-crop", "bad.jpg"],
            ["keypress", "cmd+unknown"], ["keypress", "a+b"],
        ]
        for arguments in invalid {
            recorderEntered = false
            XCTAssertThrowsError(try CLI.run(arguments: arguments), "\(arguments)")
            XCTAssertFalse(recorderEntered, "validation reached recorder: \(arguments)")
        }
    }

    func testTypeDelimiterAndUTF16Budget() throws {
        for text in ["--fast", "--precise", "--json", "--", "", "hello world", "한글 😀\r\nLine2"] {
            let literal = try CLI.parseTypeOptions(["--", text])
            XCTAssertEqual(literal.text, text)
            XCTAssertFalse(literal.fast)
            let fast = try CLI.parseTypeOptions(["--fast", "--", text])
            XCTAssertEqual(fast.text, text)
            XCTAssertTrue(fast.fast)
        }
        XCTAssertEqual(try CLI.parseTypeOptions(["plain"]).text, "plain")
        XCTAssertTrue(try CLI.parseTypeOptions(["--fast", "plain"]).fast)
        XCTAssertEqual(try CLI.parseTypeOptions([String(repeating: "😀", count: 4096)]).text.utf16.count, 8192)
        for args in [[], ["--"], ["--fast"], ["--fast", "--"], ["--fast", "--fast"],
                     ["--unknown"], ["one", "two"], ["--", "one", "two"],
                     [String(repeating: "😀", count: 4097)]] {
            XCTAssertThrowsError(try CLI.parseTypeOptions(args), "\(args.prefix(3))")
        }
        let output = CLIOutput(json: true)
        try CLI.typeText(args: ["--", ""], output: output)
        let payload = try XCTUnwrap(output.lastEmission?.payload as? [String: Any])
        XCTAssertEqual(payload["accepted"] as? Bool, true)
        XCTAssertEqual(payload["inputUnits"] as? Int, 0)
    }

    func testValidInvocationMatrixAndGlobalOrdering() throws {
        let valid = [
            [], ["help"], ["--help"], ["-h"], ["doctor"], ["state"],
            ["cursor-position"], ["screen-size"], ["open-url", "https://example.com"],
            ["wait", "0"], ["wait", "20000"], ["scroll", "-2147483648", "2147483647"],
            ["move", "1", "2", "--precise", "--screen"],
            ["mousedown", "1", "2", "middle", "--fast"], ["mouseup", "right"], ["mouseup"],
            ["click", "1", "2", "right", "--post-crop", "/tmp/cli-fixture.png"],
            ["type", "--", "--fast"], ["type", "--fast", "--", "--fast"],
            ["clipboard", "get"], ["clipboard", "set", "one text"],
            ["clipboard", "copy"], ["clipboard", "paste"],
            ["app", "list"], ["app", "activate", "Activity Monitor"],
            ["window", "list"], ["window", "activate", "2147483647"],
            ["screenshot", "a.png"], ["screenshot", "a.png", "screen"],
            ["screenshot", "a.png", "window"], ["screenshot", "--screen", "a.png"],
            ["screenshot", "--region", "10", "20", "100", "80", "a.PNG"],
            ["onboard", "--no-wait", "--no-request", "--no-open"],
            ["onboard", "--wait", "--timeout", "30"], ["onboard", "--timeout", "0", "--no-wait"],
            ["keypress", "cmd+shift+a"], ["keypress", "ctrl"], ["keypress", "return"],
        ]
        for args in valid {
            XCTAssertNoThrow(try CLI.validateInvocation(args), "\(args)")
        }
        for flags in [["--json", "--relative"], ["--relative", "--json"]] {
            let invocation = try CLI.validateInvocation(flags + ["move", "0", "1000"])
            XCTAssertEqual(invocation.command, "move")
            XCTAssertEqual(invocation.args, ["0", "1000"])
            XCTAssertTrue(invocation.json)
            XCTAssertTrue(invocation.relative)
        }
        XCTAssertEqual(try CLI.parseWait(["0"]), 0)
        XCTAssertEqual(try CLI.parseWait(["20000"]), 20000)
    }

    func testInvalidSyntaxMatrix() {
        let invalid = [
            ["--unknown"], ["help", "extra"], ["--help", "extra"],
            ["wait"], ["wait", "2147483648"], ["wait", "1.0"],
            ["wait", "0", "--json"], ["--relative", "move", "1001", "0"],
            ["--relative", "click", "0", "-1"], ["move", "1", "2", "right"],
            ["mousedown", "1", "2", "extra", "extra"], ["mouseup", "extra"],
            ["scroll", "0"], ["scroll", "0", "0", "extra"],
            ["type", "--relative", "text"], ["type", "--json"],
            ["screenshot", "a.jpg"], ["screenshot", "a.png/"], ["screenshot", "a.png", "desktop"],
            ["click", "1", "2", "--post-crop", "a.png/"],
            ["screenshot", "a.png", "window", "extra"],
            ["screenshot", "--screen", "a.png", "screen"],
            ["screenshot", "--screen", "--screen", "a.png"],
            ["screenshot", "--region", "0", "0", "10", "10", "a.png", "window"],
            ["screenshot", "--region", "0", "0", "10", "10", "--region", "0", "0", "1", "1", "a.png"],
            ["--relative", "screenshot", "--region", "900", "0", "101", "100", "a.png"],
            ["--relative", "screenshot", "--region", "0", "0", "1000", "1001", "a.png"],
            ["onboard", "--timeout"], ["onboard", "--timeout", "-1"],
            ["onboard", "--timeout", "1", "--timeout", "1"],
            ["onboard", "--wait", "--wait"], ["onboard", "--no-wait", "--no-wait"],
            ["onboard", "--no-request", "--no-request"],
            ["onboard", "--no-wait", "--timeout", "1"], ["onboard", "--timeout", "0", "--wait"],
            ["clipboard"], ["clipboard", "unknown"], ["clipboard", "set"],
            ["clipboard", "set", "one", "two"], ["app", "activate", ""],
            ["app", "activate", "--unknown"], ["app", "unknown"],
            ["window", "activate", "0"], ["window", "activate", "-1"], ["window", "activate", "4294967296"],
            ["open-url", "relative/path"], ["open-url", "https://example.com", "extra"],
            ["keypress", ""], ["keypress", "cmd++a"], ["keypress", "cmd+command+a"],
            ["keypress", "a+"], ["keypress", "a", "extra"],
        ]
        for args in invalid {
            XCTAssertThrowsError(try CLI.validateInvocation(args), "\(args)") { error in
                XCTAssertEqual((error as? CUAError)?.code, "invalid_arguments")
            }
        }
    }

    func testRegionUsesSelectedWindowAndFullRelativeExtent() throws {
        let window = WindowRecord(id: 42, pid: 123, appName: "Fixture", title: "fixture",
                                  bounds: CGRect(x: 100, y: 80, width: 500, height: 400),
                                  layer: 0, onScreen: true, isFrontmost: true)
        let primary = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let context = CoordinateSupport.context(explicitScreen: false, relative: false, frontmostWindow: window,
                                                primaryBounds: primary, displayBounds: [primary])
        let options = try CLI.parseScreenshotOptions(["--region", "10", "20", "100", "80", "a.png"])
        XCTAssertFalse(options.explicitScreen)
        XCTAssertEqual(try CLI.screenshotTarget(options: options, context: context),
                       .region(CGRect(x: 110, y: 100, width: 100, height: 80)))
        let relative = CoordinateSupport.context(explicitScreen: false, relative: true, frontmostWindow: window,
                                                 primaryBounds: primary, displayBounds: [primary])
        let full = try CLI.parseScreenshotOptions(["--region", "0", "0", "1000", "1000", "a.png"])
        let relativeTarget = try CLI.screenshotTarget(options: full, context: relative)
        XCTAssertEqual(relativeTarget, .region(window.bounds))
        let plan = try ScreenshotSupport.plan(target: relativeTarget, context: relative)
        XCTAssertEqual(plan.screenBounds, window.bounds)
        XCTAssertEqual(plan.reportedBounds, CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(plan.coordinateSpace, .window)
        XCTAssertTrue(plan.relative)
        XCTAssertEqual(plan.content, "visible-desktop")
        let screen = CoordinateSupport.context(explicitScreen: true, relative: false, frontmostWindow: window,
                                               primaryBounds: primary, displayBounds: [primary])
        let explicit = try CLI.parseScreenshotOptions(["--screen", "--region", "10", "20", "100", "80", "a.png"])
        XCTAssertEqual(try CLI.screenshotTarget(options: explicit, context: screen),
                       .region(CGRect(x: 10, y: 20, width: 100, height: 80)))
    }

    func testActivationAndPostCropFailurePreserveMachineResult() throws {
        XCTAssertNoThrow(try CLI.requireActivation(["ok": true], subject: "window 1"))
        for payload: [String: Any] in [["ok": false, "id": 1], ["id": 1]] {
            XCTAssertThrowsError(try CLI.requireActivation(payload, subject: "window 1")) { error in
                do {
                    let detail = try XCTUnwrap(try errorPayload(error)["error"] as? [String: Any])
                    XCTAssertEqual(detail["code"] as? String, "activation_failed")
                    XCTAssertEqual((detail["result"] as? [String: Any])?["id"] as? Int, 1)
                } catch { XCTFail("\(error)") }
            }
        }
        var attemptedCapture = false
        XCTAssertThrowsError(try CLI.captureAfterClick {
            attemptedCapture = true
            throw CUAError(message: "fixture capture error")
        }) { error in
            do {
                let detail = try XCTUnwrap(try errorPayload(error)["error"] as? [String: Any])
                XCTAssertEqual(detail["code"] as? String, "post_crop_failed")
                let result = try XCTUnwrap(detail["result"] as? [String: Any])
                XCTAssertEqual(result["clickOccurred"] as? Bool, true)
                XCTAssertEqual(result["captureFailed"] as? Bool, true)
            } catch { XCTFail("\(error)") }
        }
        XCTAssertTrue(attemptedCapture)
        XCTAssertEqual(try CLI.captureAfterClick { ["path": "a.png"] }["path"] as? String, "a.png")
    }

    func testHumanCursorAndScreenEmissionsAreNotEmpty() throws {
        let cursor = CLIOutput(json: false)
        try CLI.cursorPosition(output: cursor)
        XCTAssertFalse(try XCTUnwrap(cursor.lastEmission?.lines).isEmpty)
        let size = CLIOutput(json: false)
        try CLI.screenSize(output: size)
        XCTAssertFalse(try XCTUnwrap(size.lastEmission?.human).isEmpty)
    }

    func testDescriptorKeepsFiveOperationsAndLiteralTypeDelimiter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("deploy/bunshin/macos-cua.json"))) as? [String: Any])
        XCTAssertEqual(descriptor["ops"] as? [String], ["cua.screenshot", "cua.cursor_position", "cua.screen_size", "cua.click", "cua.type"])
        let sidecar = try XCTUnwrap(descriptor["sidecar"] as? [String: Any])
        XCTAssertEqual(sidecar["timeoutMs"] as? Int, 20000)
        let commands = try XCTUnwrap(sidecar["commands"] as? [String: [String: Any]])
        XCTAssertEqual(commands["cua.type"]?["args"] as? [String], ["type", "--", "{text}"])
    }

    func testExecutableInvalidArgumentsUseNonzeroStructuredOrStderrErrors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for arguments in [["--json", "wait", "-1"], ["--relative", "--json", "wait", "20001"],
                          ["--json", "--json", "wait", "0"], ["wait", "-1"],
                          ["--json", "--relative", "wait", "0"], ["--relative", "wait", "0"]] {
            let process = Process()
            process.executableURL = root.appendingPathComponent(".build/debug/macos-cua")
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let terminated = expectation(description: "invalid invocation exits")
            process.terminationHandler = { _ in terminated.fulfill() }
            try process.run()
            wait(for: [terminated], timeout: 10)
            if process.isRunning {
                process.terminate()
                XCTFail("invalid invocation failed to terminate")
                return
            }
            XCTAssertEqual(process.terminationStatus, 1)
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            if arguments.contains("--json") {
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: [String: Any]])
                XCTAssertEqual(payload["error"]?["code"] as? String, "invalid_arguments")
                XCTAssertNotNil(payload["error"]?["message"] as? String)
                XCTAssertTrue(err.isEmpty)
            } else {
                XCTAssertTrue(out.isEmpty)
                XCTAssertFalse(err.isEmpty)
            }
        }
        XCTAssertFalse(CLI.requestsJSON(["type", "--", "--json"]))
        XCTAssertTrue(CLI.requestsJSON(["--relative", "--json", "wait", "-1"]))
    }


    func testNativeWindowIDsUseUInt32RangeBeforeEffects() {
        for id in ["1", "2147483647", "2147483648", "4294967295"] {
            XCTAssertNoThrow(try CLI.validateInvocation(["window", "activate", id]), id)
        }
        let previous = Recorder.environment
        defer { Recorder.environment = previous }
        var recorderEntered = false
        Recorder.environment.baseDirectory = {
            recorderEntered = true
            throw CUAError(message: "recorder sentinel")
        }
        for id in ["0", "-1", "4294967296", "18446744073709551616", "1.5", ""] {
            XCTAssertThrowsError(try CLI.run(arguments: ["window", "activate", id]), id)
            XCTAssertFalse(recorderEntered, id)
        }
    }


    func testDoctorReadinessRequiresCaptureSuccess() {
        XCTAssertTrue(CLI.doctorReady(accessibility: true, screenRecording: true, screenshotCheck: ["ok": true]))
        XCTAssertFalse(CLI.doctorReady(accessibility: true, screenRecording: true, screenshotCheck: ["ok": false]))
        XCTAssertFalse(CLI.doctorReady(accessibility: true, screenRecording: true, screenshotCheck: [:]))
        XCTAssertFalse(CLI.doctorReady(accessibility: false, screenRecording: true, screenshotCheck: ["ok": true]))
        XCTAssertFalse(CLI.doctorReady(accessibility: true, screenRecording: false, screenshotCheck: ["ok": true]))
    }

    func testRelativeRejectsNonCoordinateCommandsBeforeRecorder() {
        let previous = Recorder.environment
        defer { Recorder.environment = previous }
        var recorderEntered = false
        Recorder.environment.baseDirectory = {
            recorderEntered = true
            throw CUAError(message: "recorder sentinel")
        }
        let commands = [
            ["type", "--", "text"], ["wait", "0"], ["doctor"],
            ["screen-size"], ["cursor-position"], ["keypress", "cmd+a"],
            ["app", "list"], ["app", "activate", "Activity Monitor"],
            ["window", "list"], ["window", "activate", "1"],
            ["clipboard", "get"], ["clipboard", "set", "text"],
            ["clipboard", "copy"], ["clipboard", "paste"],
            ["scroll", "0", "0"], ["mouseup"],
            ["open-url", "https://example.com"],
            ["onboard", "--no-wait", "--no-request", "--no-open"],
            ["onboarding", "--no-wait", "--no-request", "--no-open"],
        ]
        for flags in [["--relative"], ["--json", "--relative"], ["--relative", "--json"]] {
            for command in commands {
                recorderEntered = false
                let arguments = flags + command
                XCTAssertThrowsError(try CLI.run(arguments: arguments), "\(arguments)") { error in
                    XCTAssertEqual((error as? CUAError)?.code, "invalid_arguments", "\(arguments)")
                }
                XCTAssertFalse(recorderEntered, "validation reached recorder: \(arguments)")
            }
            for help in [[], ["help"], ["--help"], ["-h"]] {
                XCTAssertThrowsError(try CLI.validateInvocation(flags + help), "\(flags + help)")
            }
        }
    }

    func testRelativeAllowsOnlyCoordinateCommandsInPrefix() throws {
        let commands = [
            ["state"], ["screenshot", "a.png"],
            ["screenshot", "--screen", "--region", "0", "0", "1000", "1000", "a.png"],
            ["move", "0", "1000", "--screen"],
            ["mousedown", "0", "1000", "right", "--precise"],
            ["click", "0", "1000", "middle", "--fast"],
        ]
        for flags in [["--relative"], ["--json", "--relative"], ["--relative", "--json"]] {
            for command in commands {
                let parsed = try CLI.validateInvocation(flags + command)
                XCTAssertEqual(parsed.command, command[0])
                XCTAssertEqual(parsed.args, Array(command.dropFirst()))
                XCTAssertTrue(parsed.relative)
                XCTAssertEqual(parsed.json, flags.contains("--json"))
                XCTAssertThrowsError(try CLI.validateInvocation(flags + ["--relative"] + command))
            }
        }
        for command in commands {
            XCTAssertThrowsError(try CLI.validateInvocation(command + ["--relative"]))
        }
        let literal = try CLI.validateInvocation(["--json", "type", "--", "--relative"])
        XCTAssertFalse(literal.relative)
        XCTAssertEqual(try CLI.parseTypeOptions(literal.args).text, "--relative")
    }

}
