import ArgumentParser
import FromoCore

@main
struct Fromo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fromo",
        abstract: "Fromo timer (M0 build)",
        version: FromoVersion.current
    )

    mutating func run() throws {
        // M0 only verifies that the bundled command-line executable launches.
    }
}
