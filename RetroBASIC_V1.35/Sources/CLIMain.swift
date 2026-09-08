import Foundation

@main
struct CLIMain {
    static func main() {
        let args = CommandLine.arguments
        let console = StdioConsole()
        let interp = Interpreter(console: console)

        if args.count > 1, args[1] != "-i" {
            guard let src = try? String(contentsOfFile: args[1], encoding: .utf8) else {
                FileHandle.standardError.write("cannot open \(args[1])\n".data(using: .utf8)!)
                exit(1)
            }
            for line in src.split(separator: "\n", omittingEmptySubsequences: false) {
                interp.processInput(String(line))
            }
            interp.handleImmediate("RUN")
            if args.contains("-i") { interp.repl() }
        } else {
            interp.repl()
        }
    }
}
