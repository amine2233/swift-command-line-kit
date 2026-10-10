import ArgumentParser
import CommandLineKit
import CommandLineKitInput
import Foundation

/// Asks the user one question and prints the answer on stdout. Prompts go to stderr.
struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Asks a question: text (default), --secret, --confirm or --choose a,b,c."
    )

    @Flag(help: "Hide what is typed and print only its length.")
    var secret = false

    @Flag(help: "Ask a yes/no question, default yes.")
    var confirm = false

    @Option(help: "Comma-separated options to choose from.")
    var choose: String?

    func run() async throws {
        let input = CommandInput.current
        if let choose {
            let options = choose.split(separator: ",").map(String.init)
            try await print("chose: \(input.choose("Pick one", from: options))")
        } else if confirm {
            try await print("confirmed: \(input.confirm("Proceed?", default: true))")
        } else if secret {
            try await print("secret length: \(input.prompt("Secret", default: nil, secret: true).count)")
        } else {
            try await print("name: \(input.prompt("Name", default: "anonymous", secret: false))")
        }
    }
}
