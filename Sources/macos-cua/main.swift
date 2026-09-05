import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    try CLI.run(arguments: arguments)
} catch {
    reportFailure(error, json: CLI.requestsJSON(arguments))
}
