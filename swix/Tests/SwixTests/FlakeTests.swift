import Testing
import Foundation
@testable import Swix

// MARK: - Builtins Tests

@Suite("Builtins")
struct BuiltinsTests {
    let evaluator = Evaluator()

    func eval(_ source: String) throws -> Value {
        let env = Builtins.baseEnv(evaluator: evaluator)
        return try evaluator.eval(source, env: env)
    }

    // --- Type checks ---

    @Test func isAttrs() throws {
        if case .bool(true) = try eval("builtins.isAttrs { }") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.isAttrs 1") {} else { Issue.record("expected false") }
    }

    @Test func isBool() throws {
        if case .bool(true) = try eval("builtins.isBool true") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.isBool 1") {} else { Issue.record("expected false") }
    }

    @Test func isInt() throws {
        if case .bool(true) = try eval("builtins.isInt 42") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.isInt \"hi\"") {} else { Issue.record("expected false") }
    }

    @Test func isList() throws {
        if case .bool(true) = try eval("builtins.isList [1 2]") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.isList 1") {} else { Issue.record("expected false") }
    }

    @Test func isString() throws {
        if case .bool(true) = try eval("builtins.isString \"hi\"") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.isString 1") {} else { Issue.record("expected false") }
    }

    @Test func isNull() throws {
        if case .bool(true) = try eval("builtins.isNull null") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.isNull 1") {} else { Issue.record("expected false") }
    }

    @Test func isFunction() throws {
        if case .bool(true) = try eval("builtins.isFunction (x: x)") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.isFunction 1") {} else { Issue.record("expected false") }
    }

    // --- typeOf ---

    @Test func typeOf() throws {
        if case .string("int") = try eval("builtins.typeOf 42") {} else { Issue.record("expected int") }
        if case .string("string") = try eval("builtins.typeOf \"hi\"") {} else { Issue.record("expected string") }
        if case .string("bool") = try eval("builtins.typeOf true") {} else { Issue.record("expected bool") }
        if case .string("null") = try eval("builtins.typeOf null") {} else { Issue.record("expected null") }
        if case .string("list") = try eval("builtins.typeOf [1]") {} else { Issue.record("expected list") }
        if case .string("set") = try eval("builtins.typeOf { }") {} else { Issue.record("expected set") }
        if case .string("lambda") = try eval("builtins.typeOf (x: x)") {} else { Issue.record("expected lambda") }
    }

    // --- Attr set operations ---

    @Test func attrNames() throws {
        let val = try eval("builtins.attrNames { z = 1; a = 2; m = 3; }")
        if case .list(let l) = val {
            let names = l.compactMap { if case .string(let s) = $0 { return s }; return nil }
            #expect(names == ["a", "m", "z"])
        } else {
            Issue.record("Expected list")
        }
    }

    @Test func attrValues() throws {
        let val = try eval("builtins.attrValues { b = 2; a = 1; }")
        if case .list(let l) = val {
            #expect(l.count == 2)
            // Sorted by key name: a=1, b=2
            if case .int(1) = l[0] {} else { Issue.record("Expected 1 first") }
            if case .int(2) = l[1] {} else { Issue.record("Expected 2 second") }
        } else {
            Issue.record("Expected list")
        }
    }

    @Test func hasAttr() throws {
        if case .bool(true) = try eval("builtins.hasAttr \"a\" { a = 1; }") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.hasAttr \"b\" { a = 1; }") {} else { Issue.record("expected false") }
    }

    @Test func getAttr() throws {
        let val = try eval("builtins.getAttr \"a\" { a = 42; }")
        if case .int(42) = val {} else { Issue.record("Expected 42, got \(val)") }
    }

    @Test func removeAttrs() throws {
        let val = try eval("builtins.removeAttrs { a = 1; b = 2; c = 3; } [\"b\"]")
        if case .attrSet(let s) = val {
            #expect(s.has("a"))
            #expect(!s.has("b"))
            #expect(s.has("c"))
        } else {
            Issue.record("Expected attrset")
        }
    }

    @Test func listToAttrs() throws {
        let val = try eval("builtins.listToAttrs [{ name = \"x\"; value = 1; } { name = \"y\"; value = 2; }]")
        if case .attrSet(let s) = val {
            #expect(s.has("x"))
            #expect(s.has("y"))
        } else {
            Issue.record("Expected attrset")
        }
    }

    @Test func mapAttrs() throws {
        let val = try eval("builtins.mapAttrs (name: value: value + 1) { a = 1; b = 2; }")
        if case .attrSet(let s) = val {
            if case .int(2) = try s.force("a", evaluator: evaluator) {} else { Issue.record("a should be 2") }
            if case .int(3) = try s.force("b", evaluator: evaluator) {} else { Issue.record("b should be 3") }
        } else {
            Issue.record("Expected attrset")
        }
    }

    @Test func intersectAttrs() throws {
        let val = try eval("builtins.intersectAttrs { a = 1; b = 2; } { b = 20; c = 30; }")
        if case .attrSet(let s) = val {
            #expect(!s.has("a"))
            #expect(s.has("b"))
            #expect(!s.has("c"))
            if case .int(20) = try s.force("b", evaluator: evaluator) {} else { Issue.record("b should be 20") }
        } else {
            Issue.record("Expected attrset")
        }
    }

    // --- List operations ---

    @Test func length() throws {
        let val = try eval("builtins.length [1 2 3]")
        if case .int(3) = val {} else { Issue.record("Expected 3") }
    }

    @Test func head() throws {
        let val = try eval("builtins.head [42 1 2]")
        if case .int(42) = val {} else { Issue.record("Expected 42") }
    }

    @Test func tail() throws {
        let val = try eval("builtins.tail [1 2 3]")
        if case .list(let l) = val { #expect(l.count == 2) }
        else { Issue.record("Expected list of 2") }
    }

    @Test func elemAt() throws {
        let val = try eval("builtins.elemAt [10 20 30] 1")
        if case .int(20) = val {} else { Issue.record("Expected 20") }
    }

    @Test func map() throws {
        let val = try eval("builtins.map (x: x * 2) [1 2 3]")
        if case .list(let l) = val {
            #expect(l.count == 3)
            if case .int(2) = l[0] {} else { Issue.record("Expected 2") }
            if case .int(4) = l[1] {} else { Issue.record("Expected 4") }
            if case .int(6) = l[2] {} else { Issue.record("Expected 6") }
        } else {
            Issue.record("Expected list")
        }
    }

    @Test func filter() throws {
        let val = try eval("builtins.filter (x: x > 2) [1 2 3 4 5]")
        if case .list(let l) = val {
            #expect(l.count == 3)
        } else {
            Issue.record("Expected list")
        }
    }

    @Test func foldl() throws {
        let val = try eval("builtins.foldl' (a: b: a + b) 0 [1 2 3 4]")
        if case .int(10) = val {} else { Issue.record("Expected 10, got \(val)") }
    }

    @Test func concatLists() throws {
        let val = try eval("builtins.concatLists [[1 2] [3] [4 5]]")
        if case .list(let l) = val { #expect(l.count == 5) }
        else { Issue.record("Expected list of 5") }
    }

    @Test func elem() throws {
        if case .bool(true) = try eval("builtins.elem 2 [1 2 3]") {} else { Issue.record("2 should be in list") }
        if case .bool(false) = try eval("builtins.elem 5 [1 2 3]") {} else { Issue.record("5 should not be in list") }
    }

    @Test func genList() throws {
        let val = try eval("builtins.genList (i: i * i) 4")
        if case .list(let l) = val {
            #expect(l.count == 4)
            if case .int(0) = l[0] {} else { Issue.record("0^2") }
            if case .int(1) = l[1] {} else { Issue.record("1^2") }
            if case .int(4) = l[2] {} else { Issue.record("2^2") }
            if case .int(9) = l[3] {} else { Issue.record("3^2") }
        } else {
            Issue.record("Expected list")
        }
    }

    @Test func concatMap() throws {
        let val = try eval("builtins.concatMap (x: [x (x * 2)]) [1 2 3]")
        if case .list(let l) = val { #expect(l.count == 6) }
        else { Issue.record("Expected list of 6") }
    }

    @Test func any() throws {
        if case .bool(true) = try eval("builtins.any (x: x > 3) [1 2 5]") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.any (x: x > 10) [1 2 5]") {} else { Issue.record("expected false") }
    }

    @Test func all() throws {
        if case .bool(true) = try eval("builtins.all (x: x > 0) [1 2 3]") {} else { Issue.record("expected true") }
        if case .bool(false) = try eval("builtins.all (x: x > 1) [1 2 3]") {} else { Issue.record("expected false") }
    }

    @Test func sort() throws {
        let val = try eval("builtins.sort (a: b: a < b) [3 1 2]")
        if case .list(let l) = val {
            if case .int(1) = l[0], case .int(2) = l[1], case .int(3) = l[2] {} else { Issue.record("not sorted") }
        } else {
            Issue.record("Expected list")
        }
    }

    // --- String operations ---

    @Test func toStringBuiltin() throws {
        if case .string("42") = try eval("builtins.toString 42") {} else { Issue.record("toString 42") }
        if case .string("hello") = try eval("builtins.toString \"hello\"") {} else { Issue.record("toString string") }
    }

    @Test func stringLength() throws {
        let val = try eval("builtins.stringLength \"hello\"")
        if case .int(5) = val {} else { Issue.record("Expected 5") }
    }

    @Test func substring() throws {
        let val = try eval("builtins.substring 1 3 \"hello\"")
        if case .string("ell") = val {} else { Issue.record("Expected ell, got \(val)") }
    }

    @Test func concatStringsSep() throws {
        let val = try eval("builtins.concatStringsSep \", \" [\"a\" \"b\" \"c\"]")
        if case .string("a, b, c") = val {} else { Issue.record("Expected 'a, b, c', got \(val)") }
    }

    @Test func replaceStrings() throws {
        let val = try eval("builtins.replaceStrings [\"o\"] [\"0\"] \"foo\"")
        if case .string("f00") = val {} else { Issue.record("Expected f00, got \(val)") }
    }

    // --- JSON ---

    @Test func toJSON() throws {
        let val = try eval("builtins.toJSON { a = 1; b = \"hello\"; }")
        if case .string(let s) = val {
            #expect(s.contains("\"a\""))
            #expect(s.contains("\"b\""))
        } else {
            Issue.record("Expected JSON string")
        }
    }

    @Test func fromJSON() throws {
        let val = try eval("builtins.fromJSON \"{\\\"a\\\": 1, \\\"b\\\": true}\"")
        if case .attrSet(let s) = val {
            #expect(s.has("a"))
            #expect(s.has("b"))
        } else {
            Issue.record("Expected attrset, got \(val)")
        }
    }

    // --- Arithmetic builtins ---

    @Test func addBuiltin() throws {
        let val = try eval("builtins.add 3 4")
        if case .int(7) = val {} else { Issue.record("Expected 7") }
    }

    @Test func subBuiltin() throws {
        let val = try eval("builtins.sub 10 3")
        if case .int(7) = val {} else { Issue.record("Expected 7") }
    }

    @Test func lessThanBuiltin() throws {
        if case .bool(true) = try eval("builtins.lessThan 1 2") {} else { Issue.record("1 < 2") }
        if case .bool(false) = try eval("builtins.lessThan 2 1") {} else { Issue.record("2 < 1") }
    }

    // --- Error builtins ---

    @Test func throwBuiltin() throws {
        #expect(throws: EvalError.self) { try eval("builtins.throw \"test error\"") }
    }

    @Test func abortBuiltin() throws {
        #expect(throws: EvalError.self) { try eval("builtins.abort \"test abort\"") }
    }

    // --- currentSystem ---

    @Test func currentSystem() throws {
        let val = try eval("builtins.currentSystem")
        if case .string(let s) = val {
            #expect(s.contains("-"))  // e.g., "aarch64-darwin"
        } else {
            Issue.record("Expected string")
        }
    }

    // --- Top-level builtins ---

    @Test func topLevelMap() throws {
        let val = try eval("map (x: x + 1) [1 2 3]")
        if case .list(let l) = val { #expect(l.count == 3) }
        else { Issue.record("Expected list") }
    }

    @Test func topLevelToString() throws {
        if case .string("42") = try eval("toString 42") {} else { Issue.record("toString 42") }
    }

    @Test func topLevelIsNull() throws {
        if case .bool(true) = try eval("isNull null") {} else { Issue.record("isNull null") }
        if case .bool(false) = try eval("isNull 1") {} else { Issue.record("isNull 1") }
    }

    @Test func topLevelThrow() throws {
        #expect(throws: EvalError.self) { try eval("throw \"err\"") }
    }

    // --- I/O builtins ---

    @Test func readFile() throws {
        let tmpFile = NSTemporaryDirectory() + "swix-test-readfile.txt"
        try "hello from file".write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let val = try eval("builtins.readFile \"\(tmpFile)\"")
        if case .string("hello from file") = val {} else { Issue.record("Expected file contents, got \(val)") }
    }

    @Test func pathExists() throws {
        let tmpFile = NSTemporaryDirectory() + "swix-test-pathexists.txt"
        try "x".write(toFile: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        if case .bool(true) = try eval("builtins.pathExists \"\(tmpFile)\"") {} else { Issue.record("should exist") }
        if case .bool(false) = try eval("builtins.pathExists \"/nonexistent/path\"") {} else { Issue.record("should not exist") }
    }

    // --- seq/deepSeq ---

    @Test func seq() throws {
        let val = try eval("builtins.seq 1 42")
        if case .int(42) = val {} else { Issue.record("Expected 42") }
    }

    // --- Complex expressions with builtins ---

    @Test func nixpkgsStyleForAllSystems() throws {
        let source = """
        let
          systems = [ "x86_64-linux" "aarch64-darwin" ];
          forAllSystems = f: builtins.listToAttrs (builtins.map (system:
            { name = system; value = f system; }
          ) systems);
        in forAllSystems (system: { inherit system; greeting = "hello from ${system}"; })
        """
        let val = try eval(source)
        if case .attrSet(let s) = val {
            #expect(s.has("x86_64-linux"))
            #expect(s.has("aarch64-darwin"))
            if case .attrSet(let inner) = try s.force("x86_64-linux", evaluator: evaluator) {
                if case .string(let g) = try inner.force("greeting", evaluator: evaluator) {
                    #expect(g == "hello from x86_64-linux")
                }
            }
        } else {
            Issue.record("Expected attrset")
        }
    }
}

// MARK: - Flake Evaluator Tests

@Suite("FlakeEvaluator")
struct FlakeEvaluatorTests {
    /// Each test gets its own unique temp dir to avoid races.
    static func makeTmpDir() throws -> String {
        let dir = NSTemporaryDirectory() + "swix-flake-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeFlake(_ dir: String, _ content: String) throws {
        let path = (dir as NSString).appendingPathComponent("flake.nix")
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func simpleFlake() throws {
        let dir = try Self.makeTmpDir()
        defer { Self.cleanup(dir) }
        try Self.writeFlake(dir, """
        {
          description = "Test flake";
          outputs = { self }: {
            hello = "world";
            answer = 42;
          };
        }
        """)

        let flake = FlakeEvaluator()
        let outputs = try flake.evalFlake(at: dir)
        guard case .attrSet(let s) = outputs else {
            Issue.record("Expected attrset outputs"); return
        }

        let evaluator = Evaluator()
        if case .string("world") = try s.force("hello", evaluator: evaluator) {} else {
            Issue.record("Expected 'world'")
        }
        if case .int(42) = try s.force("answer", evaluator: evaluator) {} else {
            Issue.record("Expected 42")
        }
    }

    @Test func flakeWithPackages() throws {
        let dir = try Self.makeTmpDir()
        defer { Self.cleanup(dir) }
        try Self.writeFlake(dir, """
        {
          description = "Packages flake";
          outputs = { self }: {
            packages.x86_64-linux.default = {
              type = "derivation";
              name = "my-pkg";
              system = "x86_64-linux";
            };
            packages.aarch64-darwin.default = {
              type = "derivation";
              name = "my-pkg";
              system = "aarch64-darwin";
            };
          };
        }
        """)

        let flake = FlakeEvaluator()
        let val = try flake.evalFlakeOutput(at: dir, path: ["packages", "x86_64-linux", "default", "name"])
        if case .string("my-pkg") = val {} else { Issue.record("Expected my-pkg, got \(val)") }
    }

    @Test func flakeMetadata() throws {
        let dir = try Self.makeTmpDir()
        defer { Self.cleanup(dir) }
        try Self.writeFlake(dir, """
        {
          description = "My test flake";
          inputs = {
            nixpkgs.url = "github:NixOS/nixpkgs";
            utils.url = "github:numtide/flake-utils";
          };
          outputs = { self, nixpkgs, utils }: {
            lib = { };
          };
        }
        """)

        let flake = FlakeEvaluator()
        let meta = try flake.flakeMetadata(at: dir)
        #expect(meta.description == "My test flake")
        #expect(meta.inputNames.contains("nixpkgs"))
        #expect(meta.inputNames.contains("utils"))
    }

    @Test func flakeShowOutput() throws {
        let dir = try Self.makeTmpDir()
        defer { Self.cleanup(dir) }
        try Self.writeFlake(dir, """
        {
          description = "Show test";
          outputs = { self }: {
            packages.x86_64-linux.hello = {
              type = "derivation";
              name = "hello-1.0";
            };
            lib.add = a: b: a + b;
          };
        }
        """)

        let flake = FlakeEvaluator()
        let show = try flake.flakeShow(at: dir)
        #expect(show.contains("hello"))
        #expect(show.contains("derivation"))
        #expect(show.contains("lib"))
    }

    @Test func flakeWithNixpkgsInput() throws {
        let dir = try Self.makeTmpDir()
        defer { Self.cleanup(dir) }
        try Self.writeFlake(dir, """
        {
          description = "Nixpkgs consumer";
          inputs.nixpkgs.url = "github:NixOS/nixpkgs";
          outputs = { self, nixpkgs }: {
            info = {
              nixpkgsHasLib = nixpkgs ? lib;
            };
          };
        }
        """)

        let flake = FlakeEvaluator()
        let outputs = try flake.evalFlake(at: dir)
        guard case .attrSet(let s) = outputs else { Issue.record("Expected attrset"); return }
        let evaluator = Evaluator()
        let info = try s.force("info", evaluator: evaluator)
        guard case .attrSet(let infoSet) = info else { Issue.record("Expected info attrset"); return }
        if case .bool(true) = try infoSet.force("nixpkgsHasLib", evaluator: evaluator) {} else {
            Issue.record("nixpkgs should have lib")
        }
    }

    @Test func flakeForAllSystems() throws {
        let dir = try Self.makeTmpDir()
        defer { Self.cleanup(dir) }
        try Self.writeFlake(dir, """
        {
          description = "Multi-system flake";
          inputs = { };
          outputs = { self }: let
            systems = [ "x86_64-linux" "aarch64-darwin" ];
          in {
            packages = builtins.listToAttrs (builtins.map (system: {
              name = system;
              value = {
                default = {
                  type = "derivation";
                  name = "hello";
                  system = system;
                };
              };
            }) systems);
          };
        }
        """)

        let flake = FlakeEvaluator()
        let outputs = try flake.evalFlake(at: dir)
        guard case .attrSet(let s) = outputs else { Issue.record("Expected attrset"); return }
        let evaluator = Evaluator()
        let pkgs = try s.force("packages", evaluator: evaluator)
        guard case .attrSet(let pkgsSet) = pkgs else { Issue.record("Expected packages attrset"); return }
        #expect(pkgsSet.has("x86_64-linux"))
        #expect(pkgsSet.has("aarch64-darwin"))
    }

    @Test func flakeMissingOutputs() throws {
        let dir = try Self.makeTmpDir()
        defer { Self.cleanup(dir) }
        try Self.writeFlake(dir, """
        {
          description = "No outputs";
        }
        """)

        let flake = FlakeEvaluator()
        #expect(throws: EvalError.self) { try flake.evalFlake(at: dir) }
    }

    @Test func flakeNotFound() throws {
        let flake = FlakeEvaluator()
        #expect(throws: EvalError.self) { try flake.evalFlake(at: "/nonexistent/path") }
    }
}

// MARK: - ValuePrinter Tests

@Suite("ValuePrinter")
struct ValuePrinterTests {
    let printer = ValuePrinter()

    @Test func printInt() throws {
        #expect(printer.print(.int(42)) == "42")
    }

    @Test func printFloat() throws {
        #expect(printer.print(.float(3.14)).hasPrefix("3.14"))
    }

    @Test func printBool() throws {
        #expect(printer.print(.bool(true)) == "true")
        #expect(printer.print(.bool(false)) == "false")
    }

    @Test func printNull() throws {
        #expect(printer.print(.null) == "null")
    }

    @Test func printString() throws {
        #expect(printer.print(.string("hello")) == "\"hello\"")
    }

    @Test func printStringWithEscapes() throws {
        #expect(printer.print(.string("a\nb")) == "\"a\\nb\"")
    }

    @Test func printEmptyList() throws {
        #expect(printer.print(.list([])) == "[ ]")
    }

    @Test func printSimpleList() throws {
        let result = printer.print(.list([.int(1), .int(2), .int(3)]))
        #expect(result == "[ 1 2 3 ]")
    }

    @Test func printEmptyAttrSet() throws {
        #expect(printer.print(.attrSet(AttrSetVal())) == "{ }")
    }

    @Test func printAttrSet() throws {
        let s = AttrSetVal()
        s.set("a", value: .int(1))
        s.set("b", value: .string("hi"))
        let result = printer.print(.attrSet(s))
        #expect(result.contains("a = 1;"))
        #expect(result.contains("b = \"hi\";"))
    }

    @Test func printJSON() throws {
        let s = AttrSetVal()
        s.set("x", value: .int(42))
        s.set("y", value: .bool(true))
        let json = printer.printJSON(.attrSet(s))
        #expect(json.contains("42"))
        #expect(json.contains("true"))
    }
}
