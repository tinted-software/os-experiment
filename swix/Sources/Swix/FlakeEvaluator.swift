// FlakeEvaluator.swift - Nix Flake Evaluator
import Foundation

/// Represents a parsed flake.nix structure.
public struct FlakeMetadata: Sendable {
    public let description: String?
    public let inputNames: [String]
    public let outputAttrNames: [String]
}

/// Evaluates flake.nix files and provides a structured view of the flake outputs.
public struct FlakeEvaluator: Sendable {
    private let evaluator: Evaluator

    public init() {
        self.evaluator = Evaluator()
    }

    // MARK: - Evaluate flake.nix

    /// Evaluate a flake.nix at the given directory, returning the full flake output attrset.
    /// Input fetching is stubbed: each input is provided as a stub attrset with metadata.
    public func evalFlake(at directory: String) throws -> Value {
        let flakePath = (directory as NSString).appendingPathComponent("flake.nix")

        guard FileManager.default.fileExists(atPath: flakePath) else {
            throw EvalError(message: "flake.nix not found at \(directory)")
        }

        let source = try String(contentsOfFile: flakePath, encoding: .utf8)
        let env = Builtins.baseEnv(evaluator: evaluator)

        // Parse and evaluate the flake.nix expression
        let flakeExpr = try evaluator.eval(source, env: env)

        guard case .attrSet(let flakeSet) = flakeExpr else {
            throw EvalError(message: "flake.nix must evaluate to an attribute set")
        }

        // Extract the outputs function
        guard flakeSet.has("outputs") else {
            throw EvalError(message: "flake.nix is missing 'outputs' attribute")
        }

        let outputsFn = try flakeSet.force("outputs", evaluator: evaluator)

        // Build the stubbed inputs
        let inputs = try buildStubbedInputs(flakeSet: flakeSet, flakeDir: directory)

        // Call the outputs function with the inputs
        let outputsVal = try Builtins.applyFn(outputsFn, arg: inputs, evaluator: evaluator)

        return outputsVal
    }

    /// Get metadata about a flake without fully evaluating outputs.
    public func flakeMetadata(at directory: String) throws -> FlakeMetadata {
        let flakePath = (directory as NSString).appendingPathComponent("flake.nix")
        let source = try String(contentsOfFile: flakePath, encoding: .utf8)
        let env = Builtins.baseEnv(evaluator: evaluator)
        let flakeExpr = try evaluator.eval(source, env: env)

        guard case .attrSet(let flakeSet) = flakeExpr else {
            throw EvalError(message: "flake.nix must evaluate to an attribute set")
        }

        // Description
        var description: String? = nil
        if flakeSet.has("description") {
            if case .string(let desc) = try flakeSet.force("description", evaluator: evaluator) {
                description = desc
            }
        }

        // Input names
        var inputNames: [String] = []
        if flakeSet.has("inputs") {
            if case .attrSet(let inputsSet) = try flakeSet.force("inputs", evaluator: evaluator) {
                inputNames = inputsSet.keys.sorted()
            }
        }

        // Try to get output attr names by calling with stubs
        var outputAttrNames: [String] = []
        if flakeSet.has("outputs") {
            let outputsFn = try flakeSet.force("outputs", evaluator: evaluator)
            let inputs = try buildStubbedInputs(flakeSet: flakeSet, flakeDir: directory)
            if let outputsVal = try? Builtins.applyFn(outputsFn, arg: inputs, evaluator: evaluator),
               case .attrSet(let outputsSet) = outputsVal {
                outputAttrNames = outputsSet.keys.sorted()
            }
        }

        return FlakeMetadata(
            description: description,
            inputNames: inputNames,
            outputAttrNames: outputAttrNames
        )
    }

    /// Evaluate a specific output path from a flake (e.g., "packages.x86_64-linux.hello").
    public func evalFlakeOutput(at directory: String, path: [String]) throws -> Value {
        let outputs = try evalFlake(at: directory)
        var current = outputs
        for key in path {
            guard case .attrSet(let s) = current else {
                throw EvalError(message: "cannot select '\(key)' from non-attribute-set")
            }
            guard s.has(key) else {
                throw EvalError(message: "attribute '\(key)' not found in flake output")
            }
            current = try s.force(key, evaluator: evaluator)
        }
        return current
    }

    // MARK: - Pretty-print flake show

    /// Generate a tree representation of flake outputs (like `nix flake show`).
    public func flakeShow(at directory: String) throws -> String {
        let outputs = try evalFlake(at: directory)
        guard case .attrSet(let outputsSet) = outputs else {
            return "(flake outputs is not an attribute set)"
        }

        var lines: [String] = []
        lines.append("git+file:///\(directory)?ref=main")

        let keys = outputsSet.keys.sorted()
        for (i, key) in keys.enumerated() {
            let isLast = (i == keys.count - 1)
            let prefix = isLast ? "└───" : "├───"
            let childPrefix = isLast ? "    " : "│   "

            let val = try? outputsSet.force(key, evaluator: evaluator)
            appendFlakeTree(key: key, value: val, prefix: prefix, childPrefix: childPrefix, lines: &lines)
        }

        return lines.joined(separator: "\n")
    }

    private func appendFlakeTree(key: String, value: Value?, prefix: String, childPrefix: String, lines: inout [String]) {
        guard let value = value else {
            lines.append("\(prefix) \(key): «error»")
            return
        }

        switch value {
        case .attrSet(let s):
            let childKeys = s.keys.sorted()
            if childKeys.isEmpty {
                lines.append("\(prefix) \(key): { }")
                return
            }

            // Detect known flake output types
            let outputType = detectOutputType(key: key, attrSet: s)
            if let type = outputType {
                lines.append("\(prefix) \(key): \(type)")
                return
            }

            lines.append("\(prefix) \(key)")
            for (j, childKey) in childKeys.enumerated() {
                let isChildLast = (j == childKeys.count - 1)
                let cp = isChildLast ? "\(childPrefix)└───" : "\(childPrefix)├───"
                let ccp = isChildLast ? "\(childPrefix)    " : "\(childPrefix)│   "
                let childVal = try? s.force(childKey, evaluator: evaluator)
                appendFlakeTree(key: childKey, value: childVal, prefix: cp, childPrefix: ccp, lines: &lines)
            }

        case .closure, .builtin:
            lines.append("\(prefix) \(key): «function»")

        case .string(let s):
            lines.append("\(prefix) \(key): \"\(s)\"")

        default:
            lines.append("\(prefix) \(key): \(value)")
        }
    }

    /// Detect common flake output types based on attribute set contents.
    private func detectOutputType(key: String, attrSet: AttrSetVal) -> String? {
        // Check if it's a derivation (has `type = "derivation"`)
        if attrSet.has("type") {
            if let typeVal = try? attrSet.force("type", evaluator: evaluator),
               case .string(let t) = typeVal {
                if t == "derivation" {
                    let name = (try? attrSet.force("name", evaluator: evaluator)).flatMap {
                        if case .string(let n) = $0 { return n }; return nil
                    } ?? "unknown"
                    return "derivation '\(name)'"
                }
                return t
            }
        }

        // Heuristics for common output types
        if key == "nixosConfigurations" || key == "darwinConfigurations" {
            return nil // Let it expand
        }

        // Check if it looks like a NixOS module (function)
        if attrSet.has("options") && attrSet.has("config") {
            return "NixOS module"
        }

        return nil
    }

    // MARK: - Stubbed Inputs

    /// Build a stubbed input attrset for calling the flake's outputs function.
    /// Since we don't actually fetch inputs, we provide stub attrsets with metadata.
    private func buildStubbedInputs(flakeSet: AttrSetVal, flakeDir: String) throws -> Value {
        let inputsAttr = AttrSetVal()

        // "self" always refers to the flake's own source
        let selfSet = AttrSetVal()
        selfSet.set("outPath", value: .string(flakeDir))
        selfSet.set("sourceInfo", value: .attrSet(makeSourceInfo(flakeDir)))
        selfSet.set("rev", value: .string("0000000000000000000000000000000000000000"))
        selfSet.set("shortRev", value: .string("0000000"))
        selfSet.set("lastModified", value: .int(0))
        selfSet.set("lastModifiedDate", value: .string("19700101000000"))
        selfSet.set("narHash", value: .string("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
        inputsAttr.set("self", value: .attrSet(selfSet))

        // Process declared inputs
        if flakeSet.has("inputs") {
            if case .attrSet(let declaredInputs) = try flakeSet.force("inputs", evaluator: evaluator) {
                for inputName in declaredInputs.keys {
                    let stubInput = try makeInputStub(
                        name: inputName,
                        spec: declaredInputs.force(inputName, evaluator: evaluator)
                    )
                    inputsAttr.set(inputName, value: .attrSet(stubInput))
                }
            }
        }

        return .attrSet(inputsAttr)
    }

    /// Create a stub input that mimics a fetched flake input.
    /// For nixpkgs-like inputs, provides a callable stub that returns a minimal pkgs set.
    private func makeInputStub(name: String, spec: Value) throws -> AttrSetVal {
        let stub = AttrSetVal()
        stub.set("outPath", value: .string("/nix/store/stub-\(name)"))
        stub.set("sourceInfo", value: .attrSet(makeSourceInfo("/nix/store/stub-\(name)")))
        stub.set("rev", value: .string("0000000000000000000000000000000000000000"))
        stub.set("shortRev", value: .string("0000000"))
        stub.set("lastModified", value: .int(0))
        stub.set("lastModifiedDate", value: .string("19700101000000"))
        stub.set("narHash", value: .string("sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))

        // For nixpkgs, provide a lib stub and make it callable
        if name == "nixpkgs" || name.hasPrefix("nixpkgs") {
            let lib = makeLibStub()
            stub.set("lib", value: .attrSet(lib))

            // nixpkgs is typically called as a function: nixpkgs { system = ...; }
            // We can't make an attrset callable directly, but the common pattern is
            // `import nixpkgs { system = ...; }` which goes through builtins.import.
            // We provide `legacyPackages` as a stub.
            let legacyPackages = AttrSetVal()
            for system in ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin"] {
                legacyPackages.set(system, value: .attrSet(makePkgsStub(system: system)))
            }
            stub.set("legacyPackages", value: .attrSet(legacyPackages))
        }

        return stub
    }

    /// Create a minimal `lib` stub with commonly-used functions.
    private func makeLibStub() -> AttrSetVal {
        let lib = AttrSetVal()

        // lib.genAttrs: [names] -> (name -> value) -> attrset
        lib.set("genAttrs", value: .builtin("lib.genAttrs") { names in
            guard case .list(let nameList) = names else {
                throw EvalError(message: "lib.genAttrs: expected list of names")
            }
            return .builtin("lib.genAttrs") { fn in
                let result = AttrSetVal()
                for nameVal in nameList {
                    guard case .string(let name) = nameVal else {
                        throw EvalError(message: "lib.genAttrs: names must be strings")
                    }
                    let val = try Builtins.applyFn(fn, arg: .string(name), evaluator: self.evaluator)
                    result.set(name, value: val)
                }
                return .attrSet(result)
            }
        })

        // lib.nixosSystem — stub
        lib.set("nixosSystem", value: .builtin("lib.nixosSystem") { _ in
            let result = AttrSetVal()
            result.set("type", value: .string("derivation"))
            result.set("name", value: .string("nixos-system"))
            result.set("system", value: .string(Builtins.currentSystem()))
            return .attrSet(result)
        })

        // lib.mkForce, lib.mkDefault, lib.mkIf — stubs that return arguments
        lib.set("mkForce", value: .builtin("lib.mkForce") { v in v })
        lib.set("mkDefault", value: .builtin("lib.mkDefault") { v in v })
        lib.set("mkIf", value: .builtin("lib.mkIf") { _ in .builtin("lib.mkIf") { v in v } })
        lib.set("mkMerge", value: .builtin("lib.mkMerge") { v in v })
        lib.set("mkOption", value: .builtin("lib.mkOption") { v in v })
        lib.set("mkEnableOption", value: .builtin("lib.mkEnableOption") { v in v })

        // lib.mapAttrs
        lib.set("mapAttrs", value: .builtin("lib.mapAttrs") { fn in
            return .builtin("lib.mapAttrs") { v2 in
                guard case .attrSet(let s) = v2 else { throw EvalError(message: "lib.mapAttrs: expected set") }
                let result = AttrSetVal()
                for key in s.keys {
                    let val = try s.force(key, evaluator: self.evaluator)
                    let partial = try Builtins.applyFn(fn, arg: .string(key), evaluator: self.evaluator)
                    let mapped = try Builtins.applyFn(partial, arg: val, evaluator: self.evaluator)
                    result.set(key, value: mapped)
                }
                return .attrSet(result)
            }
        })

        // lib.filterAttrs
        lib.set("filterAttrs", value: .builtin("lib.filterAttrs") { fn in
            return .builtin("lib.filterAttrs") { v2 in
                guard case .attrSet(let s) = v2 else { throw EvalError(message: "lib.filterAttrs: expected set") }
                let result = AttrSetVal()
                for key in s.keys {
                    let val = try s.force(key, evaluator: self.evaluator)
                    let partial = try Builtins.applyFn(fn, arg: .string(key), evaluator: self.evaluator)
                    let keep = try Builtins.applyFn(partial, arg: val, evaluator: self.evaluator)
                    if case .bool(true) = keep { result.set(key, value: val) }
                }
                return .attrSet(result)
            }
        })

        // lib.attrNames, lib.attrValues
        lib.set("attrNames", value: .builtin("lib.attrNames") { v in
            guard case .attrSet(let s) = v else { throw EvalError(message: "lib.attrNames: expected set") }
            return .list(s.keys.sorted().map { .string($0) })
        })
        lib.set("attrValues", value: .builtin("lib.attrValues") { v in
            guard case .attrSet(let s) = v else { throw EvalError(message: "lib.attrValues: expected set") }
            return .list(try s.keys.sorted().map { try s.force($0, evaluator: self.evaluator) })
        })

        // lib.optional / lib.optionals
        lib.set("optional", value: .builtin("lib.optional") { cond in
            return .builtin("lib.optional") { val in
                guard case .bool(let b) = cond else { throw EvalError(message: "lib.optional: expected bool") }
                return b ? .list([val]) : .list([])
            }
        })
        lib.set("optionals", value: .builtin("lib.optionals") { cond in
            return .builtin("lib.optionals") { val in
                guard case .bool(let b) = cond else { throw EvalError(message: "lib.optionals: expected bool") }
                if !b { return .list([]) }
                guard case .list = val else { throw EvalError(message: "lib.optionals: expected list") }
                return val
            }
        })

        // lib.flatten
        lib.set("flatten", value: .builtin("lib.flatten") { v in
            guard case .list(let l) = v else { throw EvalError(message: "lib.flatten: expected list") }
            var result: [Value] = []
            func flattenInto(_ items: [Value]) {
                for item in items {
                    if case .list(let inner) = item { flattenInto(inner) }
                    else { result.append(item) }
                }
            }
            flattenInto(l)
            return .list(result)
        })

        // lib.concatMapAttrs
        lib.set("concatMapAttrs", value: .builtin("lib.concatMapAttrs") { fn in
            return .builtin("lib.concatMapAttrs") { v2 in
                guard case .attrSet(let s) = v2 else { throw EvalError(message: "lib.concatMapAttrs: expected set") }
                let result = AttrSetVal()
                for key in s.keys {
                    let val = try s.force(key, evaluator: self.evaluator)
                    let partial = try Builtins.applyFn(fn, arg: .string(key), evaluator: self.evaluator)
                    let mapped = try Builtins.applyFn(partial, arg: val, evaluator: self.evaluator)
                    if case .attrSet(let ms) = mapped {
                        for mk in ms.keys { result.set(mk, value: try ms.force(mk, evaluator: self.evaluator)) }
                    }
                }
                return .attrSet(result)
            }
        })

        // lib.systems.flakeExposed
        let systems = AttrSetVal()
        systems.set("flakeExposed", value: .list([
            .string("x86_64-linux"), .string("aarch64-linux"),
            .string("x86_64-darwin"), .string("aarch64-darwin"),
        ]))
        lib.set("systems", value: .attrSet(systems))

        return lib
    }

    private func makePkgsStub(system: String) -> AttrSetVal {
        let pkgs = AttrSetVal()
        pkgs.set("system", value: .string(system))
        // mkDerivation stub
        pkgs.set("stdenv", value: .attrSet({
            let stdenv = AttrSetVal()
            stdenv.set("mkDerivation", value: .builtin("mkDerivation") { args in
                guard case .attrSet(let a) = args else {
                    throw EvalError(message: "mkDerivation: expected attribute set")
                }
                let result = AttrSetVal()
                result.set("type", value: .string("derivation"))
                let name = (try? a.force("pname", evaluator: self.evaluator))
                    ?? (try? a.force("name", evaluator: self.evaluator))
                    ?? .string("unknown")
                result.set("name", value: name)
                result.set("system", value: .string(system))
                if case .string(let n) = name {
                    result.set("outPath", value: .string("/nix/store/stub-\(n)"))
                    result.set("drvPath", value: .string("/nix/store/stub-\(n).drv"))
                }
                // Copy version if present
                if a.has("version"), let v = try? a.force("version", evaluator: self.evaluator) {
                    result.set("version", value: v)
                }
                return .attrSet(result)
            })
            stdenv.set("system", value: .string(system))
            stdenv.set("isDarwin", value: .bool(system.hasSuffix("-darwin")))
            stdenv.set("isLinux", value: .bool(system.hasSuffix("-linux")))
            return stdenv
        }()))
        // callPackage stub
        pkgs.set("callPackage", value: .builtin("callPackage") { fn in
            return .builtin("callPackage") { _ in
                // Try calling fn with an empty set if it's a function
                if case .closure(let c) = fn {
                    let emptyArgs = AttrSetVal()
                    emptyArgs.set("lib", value: .attrSet(self.makeLibStub()))
                    emptyArgs.set("stdenv", value: .attrSet(AttrSetVal()))
                    return (try? self.evaluator.applyClosure(c, arg: .attrSet(emptyArgs))) ?? .null
                }
                return fn
            }
        })
        // writeShellScriptBin, writeText etc. — stubs
        pkgs.set("writeShellScriptBin", value: .builtin("writeShellScriptBin") { name in
            return .builtin("writeShellScriptBin") { _ in
                let r = AttrSetVal()
                r.set("type", value: .string("derivation"))
                r.set("name", value: name)
                if case .string(let n) = name {
                    r.set("outPath", value: .string("/nix/store/stub-\(n)"))
                }
                return .attrSet(r)
            }
        })
        pkgs.set("lib", value: .attrSet(makeLibStub()))
        return pkgs
    }

    private func makeSourceInfo(_ outPath: String) -> AttrSetVal {
        let si = AttrSetVal()
        si.set("outPath", value: .string(outPath))
        return si
    }
}
