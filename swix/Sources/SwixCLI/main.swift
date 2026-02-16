// main.swift - Swix CLI (nix-compatible command interface)
import Foundation
import Swix

// MARK: - CLI Entry Point

let args = Array(CommandLine.arguments.dropFirst())

guard !args.isEmpty else {
    printUsage()
    exit(1)
}

do {
    switch args[0] {
    case "eval":
        try handleEval(args: Array(args.dropFirst()))
    case "flake":
        try handleFlake(args: Array(args.dropFirst()))
    case "build":
        try handleBuild(args: Array(args.dropFirst()))
    case "--help", "-h", "help":
        printUsage()
    case "--version":
        print("swix 0.1.0 (Nix-compatible evaluator in Swift)")
    default:
        printError("Unknown command: \(args[0])")
        printUsage()
        exit(1)
    }
} catch let error as EvalError {
    printError("error: \(error.message)")
    exit(1)
} catch let error as ParserError {
    printError("error: \(error)")
    exit(1)
} catch let error as LexerError {
    printError("error: \(error)")
    exit(1)
} catch {
    printError("error: \(error)")
    exit(1)
}

// MARK: - Usage

func printUsage() {
    let usage = """
    swix — A Nix-compatible expression evaluator

    USAGE:
      swix eval --expr '<expr>'          Evaluate a Nix expression
      swix eval -f <file>                Evaluate a Nix file
      swix eval .#<attr>                 Evaluate a flake output attribute
      swix flake show [<dir>]            Show flake output structure
      swix flake metadata [<dir>]        Show flake metadata
      swix build [<installable>]         Build a derivation (stub)
      swix --version                     Show version

    OPTIONS:
      --json                             Output as JSON
      --raw                              Output strings without quotes

    EXAMPLES:
      swix eval --expr '1 + 2'
      swix eval --expr '{ a = 1; b = 2; }'
      swix eval --expr 'let x = 42; in x'
      swix eval --expr 'builtins.map (x: x * 2) [1 2 3]'
      swix eval -f ./default.nix
      swix flake show .
      swix build .#packages.aarch64-darwin.hello
    """
    print(usage)
}

func printError(_ msg: String) {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
}

// MARK: - eval command

func handleEval(args: [String]) throws {
    var expr: String? = nil
    var filePath: String? = nil
    var flakeRef: String? = nil
    var outputJSON = false
    var outputRaw = false
    var i = 0

    while i < args.count {
        switch args[i] {
        case "--expr", "-E":
            i += 1
            guard i < args.count else {
                printError("error: --expr requires an argument")
                exit(1)
            }
            expr = args[i]
        case "-f", "--file":
            i += 1
            guard i < args.count else {
                printError("error: -f requires a file path")
                exit(1)
            }
            filePath = args[i]
        case "--json":
            outputJSON = true
        case "--raw":
            outputRaw = true
        default:
            // Check for flake reference (e.g., .#packages.x86_64-linux.hello)
            if args[i].contains("#") || args[i].starts(with: ".") {
                flakeRef = args[i]
            } else if expr == nil && filePath == nil && flakeRef == nil {
                // Treat as expression
                expr = args[i]
            } else {
                printError("error: unexpected argument '\(args[i])'")
                exit(1)
            }
        }
        i += 1
    }

    let evaluator = Evaluator()
    let value: Value

    if let expr = expr {
        // Evaluate expression
        let env = Builtins.baseEnv(evaluator: evaluator)
        value = try evaluator.eval(expr, env: env)
    } else if let filePath = filePath {
        // Evaluate file
        let resolvedPath = resolveFilePath(filePath)
        let env = Builtins.baseEnv(evaluator: evaluator)
        value = try evaluator.evalFile(resolvedPath, env: env)
    } else if let ref = flakeRef {
        // Evaluate flake output
        let (dir, attrPath) = parseFlakeRef(ref)
        let flakeEval = FlakeEvaluator()
        if attrPath.isEmpty {
            value = try flakeEval.evalFlake(at: dir)
        } else {
            value = try flakeEval.evalFlakeOutput(at: dir, path: attrPath)
        }
    } else {
        printError("error: no expression, file, or flake reference provided")
        printError("Try: swix eval --expr '<expr>'")
        exit(1)
        return // unreachable, satisfies compiler
    }

    // Output
    if outputJSON {
        let printer = ValuePrinter(evaluator: evaluator)
        print(printer.printJSON(value))
    } else if outputRaw {
        if case .string(let s) = value {
            print(s, terminator: "")
        } else {
            let printer = ValuePrinter(evaluator: evaluator)
            print(printer.print(value))
        }
    } else {
        let printer = ValuePrinter(evaluator: evaluator)
        print(printer.print(value))
    }
}

// MARK: - flake command

func handleFlake(args: [String]) throws {
    guard !args.isEmpty else {
        printError("error: flake subcommand required (show, metadata)")
        exit(1)
        return
    }

    switch args[0] {
    case "show":
        let dir = args.count > 1 ? resolveFlakeDir(args[1]) : FileManager.default.currentDirectoryPath
        let flakeEval = FlakeEvaluator()
        let output = try flakeEval.flakeShow(at: dir)
        print(output)

    case "metadata":
        let dir = args.count > 1 ? resolveFlakeDir(args[1]) : FileManager.default.currentDirectoryPath
        let flakeEval = FlakeEvaluator()
        let meta = try flakeEval.flakeMetadata(at: dir)
        print("Description: \(meta.description ?? "(none)")")
        print("Inputs:")
        for input in meta.inputNames {
            print("  └── \(input)")
        }
        if !meta.outputAttrNames.isEmpty {
            print("Output attributes:")
            for attr in meta.outputAttrNames {
                print("  └── \(attr)")
            }
        }

    case "init":
        try handleFlakeInit(args: Array(args.dropFirst()))

    default:
        printError("error: unknown flake subcommand '\(args[0])'")
        printError("Available: show, metadata, init")
        exit(1)
    }
}

func handleFlakeInit(args: [String]) throws {
    let dir = args.first ?? "."
    let flakePath = (dir as NSString).appendingPathComponent("flake.nix")

    if FileManager.default.fileExists(atPath: flakePath) {
        printError("error: flake.nix already exists at \(dir)")
        exit(1)
    }

    let template = """
    {
      description = "A basic flake";

      inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
      };

      outputs = { self, nixpkgs }: {
        packages.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.hello;
        packages.aarch64-darwin.default = nixpkgs.legacyPackages.aarch64-darwin.hello;
      };
    }

    """

    try template.write(toFile: flakePath, atomically: true, encoding: .utf8)
    print("Created \(flakePath)")
}

// MARK: - build command (stub)

func handleBuild(args: [String]) throws {
    var installable: String? = nil
    var dryRun = false
    var i = 0

    while i < args.count {
        switch args[i] {
        case "--dry-run":
            dryRun = true
        case "--help", "-h":
            print("""
            swix build [installable]

            Build a Nix derivation.
            NOTE: Build execution is currently stubbed — only evaluation is performed.

            EXAMPLES:
              swix build .#packages.x86_64-linux.hello
              swix build .                               (builds default package)
              swix build --dry-run .
            """)
            return
        default:
            installable = args[i]
        }
        i += 1
    }

    let ref = installable ?? "."
    let (dir, attrPath) = parseFlakeRef(ref)

    // Resolve what to build
    let effectivePath: [String]
    if attrPath.isEmpty {
        // Default: packages.<system>.default
        effectivePath = ["packages", Builtins.currentSystem(), "default"]
    } else {
        effectivePath = attrPath
    }

    printError("evaluating '\(ref)'...")

    let flakeEval = FlakeEvaluator()
    let value: Value

    do {
        value = try flakeEval.evalFlakeOutput(at: dir, path: effectivePath)
    } catch {
        // Try without "default" suffix
        if effectivePath.last == "default" {
            let shorter = Array(effectivePath.dropLast())
            if !shorter.isEmpty {
                printError("note: trying \(shorter.joined(separator: "."))...")
                let v2 = try flakeEval.evalFlakeOutput(at: dir, path: shorter)
                printBuildResult(v2, dryRun: dryRun)
                return
            }
        }
        throw error
    }

    printBuildResult(value, dryRun: dryRun)
}

func printBuildResult(_ value: Value, dryRun: Bool) {
    if case .attrSet(let s) = value {
        let evaluator = Evaluator()
        let name = (try? s.force("name", evaluator: evaluator)).flatMap {
            if case .string(let n) = $0 { return n }; return nil
        } ?? "unknown"
        let outPath = (try? s.force("outPath", evaluator: evaluator)).flatMap {
            if case .string(let p) = $0 { return p }; return nil
        } ?? "/nix/store/stub-output"

        if dryRun {
            print("would build: \(name)")
            print("  out: \(outPath)")
        } else {
            printError("warning: build execution is stubbed — only evaluation was performed")
            print("evaluated: \(name)")
            print("  drv: \(outPath).drv (stub)")
            print("  out: \(outPath)")
        }
    } else {
        print("result: \(value)")
        printError("warning: result is not a derivation")
    }
}

// MARK: - Helpers

func resolveFilePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(path)
}

func resolveFlakeDir(_ ref: String) -> String {
    let dir = ref.hasPrefix("/") ? ref : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(ref)
    // Strip trailing path separators
    return (dir as NSString).standardizingPath
}

/// Parse a flake reference like ".#packages.x86_64-linux.hello" into (dir, [attrPath]).
func parseFlakeRef(_ ref: String) -> (String, [String]) {
    let parts = ref.split(separator: "#", maxSplits: 1)
    let dirPart = String(parts[0])
    let dir = resolveFlakeDir(dirPart.isEmpty ? "." : dirPart)

    if parts.count > 1 {
        let attrPath = String(parts[1]).split(separator: ".").map(String.init)
        return (dir, attrPath)
    }

    return (dir, [])
}
