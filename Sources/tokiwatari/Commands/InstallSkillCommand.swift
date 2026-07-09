import ArgumentParser
import Foundation

struct InstallSkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-skill",
        abstract: "install the bundled agent skill (SKILL.md + references) to the given directory"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "install destination, e.g. ~/.claude/skills/tokiwatari")
    var dest: String

    func run() throws {
        try runReporting(global) {
            let destination = (dest as NSString).expandingTildeInPath
            let fileManager = FileManager.default

            for file in BundledSkills.files {
                let target = (destination as NSString).appendingPathComponent(file.path)
                try fileManager.createDirectory(
                    atPath: (target as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                guard let contents = Data(base64Encoded: file.base64Contents) else {
                    throw CliError("bundled skill is corrupted: \(file.path)", "Rebuild tokiwatari (scripts/embed-skills.sh).")
                }
                try contents.write(to: URL(fileURLWithPath: target))
            }

            let files = BundledSkills.files.map(\.path).sorted()
            let data: [String: Any] = ["dest": destination, "files": files]
            printSuccess(json: global.json, data: data) {
                (["installed tokiwatari skill to \(destination)"] + files.map { "  \($0)" }).joined(separator: "\n")
            }
        }
    }
}
