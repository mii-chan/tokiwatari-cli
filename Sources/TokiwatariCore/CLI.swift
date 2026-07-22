import ArgumentParser
import Foundation

struct TokiwatariCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tokiwatari",
        abstract: "Search iOS debug event logs (UI events + API calls merged into one timeline) recorded by the Tokiwatari SDK",
        version: BuildInfo.version,
        subcommands: [
            SessionsCommand.self,
            TimelineCommand.self,
            AroundCommand.self,
            UiCommand.self,
            ApiCommand.self,
            ShowCommand.self,
            QueryCommand.self,
            DoctorCommand.self,
            InstallSkillCommand.self,
        ]
    )
}

/// Global flags are accepted both before and after the subcommand name
/// ArgumentParser only parses options declared on the subcommand, so pre-subcommand global flags are moved after it.
func normalizeArguments(_ arguments: [String]) -> [String] {
    let subcommands: Set<String> = ["sessions", "timeline", "around", "ui", "api", "show", "query", "doctor", "install-skill"]
    let valueTakingGlobals: Set<String> = ["--bundle-id", "--udid", "--db", "--source"]
    let booleanGlobals: Set<String> = ["--json", "--refresh"]

    var leading: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if subcommands.contains(argument) {
            return [argument] + Array(arguments[(index + 1)...]) + leading
        }
        if valueTakingGlobals.contains(argument), index + 1 < arguments.count {
            leading.append(contentsOf: arguments[index...(index + 1)])
            index += 2
            continue
        }
        if booleanGlobals.contains(argument) {
            leading.append(argument)
            index += 1
            continue
        }
        return arguments
    }
    return arguments
}

/// Parse diagnostics echo argv, so ArgumentParser is driven manually and its
/// output routed through sanitizedForTerminal (help/version: stdout + exit 0).
public enum TokiwatariEntry {
    public static func run() {
        do {
            var command = try TokiwatariCLI.parseAsRoot(normalizeArguments(Array(CommandLine.arguments.dropFirst())))
            try command.run()
        } catch {
            let exitCode = TokiwatariCLI.exitCode(for: error)
            let message = TokiwatariCLI.fullMessage(for: error)
            if !message.isEmpty {
                if exitCode.isSuccess {
                    print(sanitizedForTerminal(message))
                } else {
                    FileHandle.standardError.write(Data((sanitizedForTerminal(message) + "\n").utf8))
                }
            }
            Foundation.exit(exitCode.rawValue)
        }
    }
}
