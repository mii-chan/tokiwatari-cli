import ArgumentParser
import Foundation

struct InstallSkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-skill",
        abstract: "install the agent skill shipped alongside the binary (SKILL.md + references) to the given directory"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "install destination, e.g. ~/.agents/skills/tokiwatari")
    var dest: String
    @Option(help: "skill source directory containing SKILL.md (default: TOKIWATARI_SKILLS_PATH, then skills/tokiwatari next to the binary, then ../share/tokiwatari/skills/tokiwatari)")
    var skillsPath: String?

    func run() throws {
        try runReporting(global) {
            let source = try resolveSkillsSource()
            let destination = (dest as NSString).expandingTildeInPath
            let fileManager = FileManager.default

            guard let enumerator = fileManager.enumerator(atPath: source) else {
                throw CliError("cannot read skill source: \(source)", Self.sourceHint)
            }
            var files: [String] = []
            for case let relative as String in enumerator {
                var isDirectory: ObjCBool = false
                let sourceFile = (source as NSString).appendingPathComponent(relative)
                guard fileManager.fileExists(atPath: sourceFile, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
                else { continue }
                let target = (destination as NSString).appendingPathComponent(relative)
                do {
                    try fileManager.createDirectory(
                        atPath: (target as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true
                    )
                    try Data(contentsOf: URL(fileURLWithPath: sourceFile)).write(to: URL(fileURLWithPath: target))
                } catch {
                    throw CliError(
                        "cannot copy \(relative) to \(destination): \(error.localizedDescription)",
                        "Check that --dest points to a writable directory."
                    )
                }
                files.append(relative)
            }
            files.sort()

            let data: [String: Any] = ["dest": destination, "files": files]
            printSuccess(json: global.json, data: data) {
                (["installed tokiwatari skill to \(destination)"] + files.map { "  \($0)" }).joined(separator: "\n")
            }
        }
    }

    private static let sourceHint = "Pass --skills-path <dir> pointing to a skill directory that contains SKILL.md (skills/tokiwatari in the release archive), or set TOKIWATARI_SKILLS_PATH."

    private func resolveSkillsSource() throws -> String {
        func containsSkill(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("SKILL.md"))
        }
        if let skillsPath {
            let path = (skillsPath as NSString).expandingTildeInPath
            guard containsSkill(path) else {
                throw CliError("no SKILL.md found at --skills-path: \(path)", Self.sourceHint)
            }
            return path
        }
        if let env = ProcessInfo.processInfo.environment["TOKIWATARI_SKILLS_PATH"], !env.isEmpty {
            let path = (env as NSString).expandingTildeInPath
            guard containsSkill(path) else {
                throw CliError("no SKILL.md found at TOKIWATARI_SKILLS_PATH: \(path)", Self.sourceHint)
            }
            return path
        }
        // Resolve bin/ symlinks (e.g. Homebrew) so relative lookups use the real install location.
        let binaryDirectory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let candidates = [
            binaryDirectory.appendingPathComponent("skills/tokiwatari").path,
            binaryDirectory.appendingPathComponent("../share/tokiwatari/skills/tokiwatari").standardizedFileURL.path,
        ]
        for candidate in candidates where containsSkill(candidate) {
            return candidate
        }
        throw CliError("no skill directory found near \(binaryDirectory.path)", Self.sourceHint)
    }
}
