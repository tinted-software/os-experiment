// Builtins.swift - Nix Built-in Functions and Values
import Foundation

/// Provides built-in Nix functions and the standard environment.
public struct Builtins: Sendable {

    /// Create a base environment with all builtins bound.
    public static func baseEnv(evaluator: Evaluator) -> Env {
        let b = AttrSetVal()

        // --- Type checks ---
        set(b, "isAttrs")    { if case .attrSet = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isBool")     { if case .bool = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isInt")      { if case .int = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isFloat")    { if case .float = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isList")     { if case .list = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isString")   { if case .string = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isNull")     { if case .null = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isPath")     { if case .path = $0 { return .bool(true) }; return .bool(false) }
        set(b, "isFunction") {
            switch $0 { case .closure, .builtin: return .bool(true); default: return .bool(false) }
        }

        // --- typeOf ---
        set(b, "typeOf") { v in
            switch v {
            case .int:     return .string("int")
            case .float:   return .string("float")
            case .bool:    return .string("bool")
            case .string:  return .string("string")
            case .path:    return .string("path")
            case .null:    return .string("null")
            case .list:    return .string("list")
            case .attrSet: return .string("set")
            case .closure, .builtin: return .string("lambda")
            }
        }

        // --- Attribute set operations ---
        set(b, "attrNames") { v in
            guard case .attrSet(let s) = v else { throw EvalError(message: "builtins.attrNames: expected set") }
            return .list(s.keys.sorted().map { .string($0) })
        }
        set(b, "attrValues") { v in
            guard case .attrSet(let s) = v else { throw EvalError(message: "builtins.attrValues: expected set") }
            return .list(try s.keys.sorted().map { try s.force($0, evaluator: evaluator) })
        }
        set(b, "hasAttr") { v in
            guard case .string(let name) = v else { throw EvalError(message: "builtins.hasAttr: expected string") }
            return .builtin("hasAttr") { v2 in
                guard case .attrSet(let s) = v2 else { throw EvalError(message: "builtins.hasAttr: expected set") }
                return .bool(s.has(name))
            }
        }
        set(b, "getAttr") { v in
            guard case .string(let name) = v else { throw EvalError(message: "builtins.getAttr: expected string") }
            return .builtin("getAttr") { v2 in
                guard case .attrSet(let s) = v2 else { throw EvalError(message: "builtins.getAttr: expected set") }
                return try s.force(name, evaluator: evaluator)
            }
        }
        set(b, "removeAttrs") { v in
            guard case .attrSet(let s) = v else { throw EvalError(message: "builtins.removeAttrs: expected set") }
            return .builtin("removeAttrs") { v2 in
                guard case .list(let names) = v2 else { throw EvalError(message: "builtins.removeAttrs: expected list") }
                let toRemove = Set(try names.map { v -> String in
                    guard case .string(let n) = v else { throw EvalError(message: "builtins.removeAttrs: list must contain strings") }
                    return n
                })
                let result = AttrSetVal()
                for key in s.keys where !toRemove.contains(key) {
                    result.set(key, value: try s.force(key, evaluator: evaluator))
                }
                return .attrSet(result)
            }
        }
        set(b, "intersectAttrs") { v in
            guard case .attrSet(let s1) = v else { throw EvalError(message: "builtins.intersectAttrs: expected set") }
            return .builtin("intersectAttrs") { v2 in
                guard case .attrSet(let s2) = v2 else { throw EvalError(message: "builtins.intersectAttrs: expected set") }
                let result = AttrSetVal()
                for key in s1.keys {
                    if s2.has(key) { result.set(key, value: try s2.force(key, evaluator: evaluator)) }
                }
                return .attrSet(result)
            }
        }
        set(b, "listToAttrs") { v in
            guard case .list(let items) = v else { throw EvalError(message: "builtins.listToAttrs: expected list") }
            let result = AttrSetVal()
            for item in items {
                guard case .attrSet(let s) = item else { throw EvalError(message: "builtins.listToAttrs: list items must be sets") }
                let name = try s.force("name", evaluator: evaluator)
                guard case .string(let n) = name else { throw EvalError(message: "builtins.listToAttrs: name must be string") }
                let value = try s.force("value", evaluator: evaluator)
                result.set(n, value: value)
            }
            return .attrSet(result)
        }
        set(b, "mapAttrs") { v in
            let fn = v
            return .builtin("mapAttrs") { v2 in
                guard case .attrSet(let s) = v2 else { throw EvalError(message: "builtins.mapAttrs: expected set") }
                let result = AttrSetVal()
                for key in s.keys {
                    let val = try s.force(key, evaluator: evaluator)
                    let mapped = try Builtins.applyFn(fn, arg: .string(key), evaluator: evaluator)
                    let mapped2 = try Builtins.applyFn(mapped, arg: val, evaluator: evaluator)
                    result.set(key, value: mapped2)
                }
                return .attrSet(result)
            }
        }

        // --- List operations ---
        set(b, "length") { v in
            guard case .list(let l) = v else {
                // Also works for strings in some Nix versions
                if case .string(let s) = v { return .int(Int64(s.count)) }
                throw EvalError(message: "builtins.length: expected list")
            }
            return .int(Int64(l.count))
        }
        set(b, "elemAt") { v in
            guard case .list(let l) = v else { throw EvalError(message: "builtins.elemAt: expected list") }
            return .builtin("elemAt") { v2 in
                guard case .int(let i) = v2 else { throw EvalError(message: "builtins.elemAt: expected int") }
                guard i >= 0 && Int(i) < l.count else { throw EvalError(message: "builtins.elemAt: index out of bounds") }
                return l[Int(i)]
            }
        }
        set(b, "head") { v in
            guard case .list(let l) = v, !l.isEmpty else { throw EvalError(message: "builtins.head: expected non-empty list") }
            return l[0]
        }
        set(b, "tail") { v in
            guard case .list(let l) = v, !l.isEmpty else { throw EvalError(message: "builtins.tail: expected non-empty list") }
            return .list(Array(l.dropFirst()))
        }
        set(b, "map") { fn in
            return .builtin("map") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.map: expected list") }
                return .list(try l.map { try Builtins.applyFn(fn, arg: $0, evaluator: evaluator) })
            }
        }
        set(b, "filter") { fn in
            return .builtin("filter") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.filter: expected list") }
                return .list(try l.filter {
                    let r = try Builtins.applyFn(fn, arg: $0, evaluator: evaluator)
                    guard case .bool(let b) = r else { throw EvalError(message: "builtins.filter: predicate must return bool") }
                    return b
                })
            }
        }
        set(b, "foldl'") { fn in
            return .builtin("foldl'") { init_ in
                return .builtin("foldl'") { v3 in
                    guard case .list(let l) = v3 else { throw EvalError(message: "builtins.foldl': expected list") }
                    var acc = init_
                    for elem in l {
                        let partial = try Builtins.applyFn(fn, arg: acc, evaluator: evaluator)
                        acc = try Builtins.applyFn(partial, arg: elem, evaluator: evaluator)
                    }
                    return acc
                }
            }
        }
        set(b, "concatLists") { v in
            guard case .list(let lists) = v else { throw EvalError(message: "builtins.concatLists: expected list") }
            var result: [Value] = []
            for item in lists {
                guard case .list(let l) = item else { throw EvalError(message: "builtins.concatLists: elements must be lists") }
                result.append(contentsOf: l)
            }
            return .list(result)
        }
        set(b, "elem") { val in
            return .builtin("elem") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.elem: expected list") }
                return .bool(l.contains { Builtins.valuesEqual(val, $0) })
            }
        }
        set(b, "genList") { fn in
            return .builtin("genList") { v2 in
                guard case .int(let n) = v2 else { throw EvalError(message: "builtins.genList: expected int") }
                guard n >= 0 else { throw EvalError(message: "builtins.genList: negative length") }
                return .list(try (0..<n).map { i in
                    try Builtins.applyFn(fn, arg: .int(i), evaluator: evaluator)
                })
            }
        }
        set(b, "concatMap") { fn in
            return .builtin("concatMap") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.concatMap: expected list") }
                var result: [Value] = []
                for item in l {
                    let mapped = try Builtins.applyFn(fn, arg: item, evaluator: evaluator)
                    guard case .list(let ml) = mapped else { throw EvalError(message: "builtins.concatMap: function must return list") }
                    result.append(contentsOf: ml)
                }
                return .list(result)
            }
        }
        set(b, "any") { fn in
            return .builtin("any") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.any: expected list") }
                for item in l {
                    let r = try Builtins.applyFn(fn, arg: item, evaluator: evaluator)
                    if case .bool(true) = r { return .bool(true) }
                }
                return .bool(false)
            }
        }
        set(b, "all") { fn in
            return .builtin("all") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.all: expected list") }
                for item in l {
                    let r = try Builtins.applyFn(fn, arg: item, evaluator: evaluator)
                    if case .bool(false) = r { return .bool(false) }
                }
                return .bool(true)
            }
        }
        set(b, "sort") { fn in
            return .builtin("sort") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.sort: expected list") }
                let sorted = try l.sorted { a, b in
                    let partial = try Builtins.applyFn(fn, arg: a, evaluator: evaluator)
                    let result = try Builtins.applyFn(partial, arg: b, evaluator: evaluator)
                    guard case .bool(let lt) = result else { throw EvalError(message: "builtins.sort: comparator must return bool") }
                    return lt
                }
                return .list(sorted)
            }
        }

        // --- String operations ---
        set(b, "toString") { v in return .string(try evaluator.coerceToString(v)) }
        set(b, "stringLength") { v in
            guard case .string(let s) = v else { throw EvalError(message: "builtins.stringLength: expected string") }
            return .int(Int64(s.count))
        }
        set(b, "substring") { v in
            guard case .int(let start) = v else { throw EvalError(message: "builtins.substring: expected int") }
            return .builtin("substring") { v2 in
                guard case .int(let len) = v2 else { throw EvalError(message: "builtins.substring: expected int") }
                return .builtin("substring") { v3 in
                    guard case .string(let s) = v3 else { throw EvalError(message: "builtins.substring: expected string") }
                    let startIdx = max(0, Int(start))
                    let endIdx = min(s.count, startIdx + Int(len))
                    if startIdx >= s.count { return .string("") }
                    let si = s.index(s.startIndex, offsetBy: startIdx)
                    let ei = s.index(s.startIndex, offsetBy: endIdx)
                    return .string(String(s[si..<ei]))
                }
            }
        }
        set(b, "concatStringsSep") { v in
            guard case .string(let sep) = v else { throw EvalError(message: "builtins.concatStringsSep: expected string") }
            return .builtin("concatStringsSep") { v2 in
                guard case .list(let l) = v2 else { throw EvalError(message: "builtins.concatStringsSep: expected list") }
                let strs = try l.map { item -> String in
                    guard case .string(let s) = item else { throw EvalError(message: "builtins.concatStringsSep: list items must be strings") }
                    return s
                }
                return .string(strs.joined(separator: sep))
            }
        }
        set(b, "replaceStrings") { v in
            guard case .list(let from) = v else { throw EvalError(message: "builtins.replaceStrings: expected list") }
            return .builtin("replaceStrings") { v2 in
                guard case .list(let to) = v2 else { throw EvalError(message: "builtins.replaceStrings: expected list") }
                return .builtin("replaceStrings") { v3 in
                    guard case .string(var s) = v3 else { throw EvalError(message: "builtins.replaceStrings: expected string") }
                    for (i, fv) in from.enumerated() {
                        guard case .string(let f) = fv, case .string(let t) = to[i] else { continue }
                        if !f.isEmpty { s = s.replacingOccurrences(of: f, with: t) }
                    }
                    return .string(s)
                }
            }
        }
        set(b, "split") { _ in
            return .builtin("split") { v2 in
                guard case .string(let s) = v2 else { throw EvalError(message: "builtins.split: expected string") }
                return .list([.string(s)])
            }
        }

        // --- Arithmetic ---
        set(b, "add") { a in .builtin("add") { b in
            switch (a, b) {
            case (.int(let x), .int(let y)): return .int(x + y)
            case (.float(let x), .float(let y)): return .float(x + y)
            case (.int(let x), .float(let y)): return .float(Double(x) + y)
            case (.float(let x), .int(let y)): return .float(x + Double(y))
            default: throw EvalError(message: "builtins.add: expected numbers")
            }
        }}
        set(b, "sub") { a in .builtin("sub") { b in
            switch (a, b) {
            case (.int(let x), .int(let y)): return .int(x - y)
            case (.float(let x), .float(let y)): return .float(x - y)
            case (.int(let x), .float(let y)): return .float(Double(x) - y)
            case (.float(let x), .int(let y)): return .float(x - Double(y))
            default: throw EvalError(message: "builtins.sub: expected numbers")
            }
        }}
        set(b, "mul") { a in .builtin("mul") { b in
            switch (a, b) {
            case (.int(let x), .int(let y)): return .int(x * y)
            default: throw EvalError(message: "builtins.mul: expected integers")
            }
        }}
        set(b, "div") { a in .builtin("div") { b in
            switch (a, b) {
            case (.int(let x), .int(let y)):
                guard y != 0 else { throw EvalError(message: "builtins.div: division by zero") }
                return .int(x / y)
            default: throw EvalError(message: "builtins.div: expected integers")
            }
        }}
        set(b, "lessThan") { a in .builtin("lessThan") { b in
            switch (a, b) {
            case (.int(let x), .int(let y)): return .bool(x < y)
            case (.string(let x), .string(let y)): return .bool(x < y)
            default: throw EvalError(message: "builtins.lessThan: expected comparable values")
            }
        }}

        // --- JSON ---
        set(b, "toJSON") { v in return .string(try Builtins.valueToJSON(v, evaluator: evaluator)) }
        set(b, "fromJSON") { v in
            guard case .string(let s) = v else { throw EvalError(message: "builtins.fromJSON: expected string") }
            return try Builtins.jsonToValue(s)
        }

        // --- I/O ---
        set(b, "readFile") { v in
            let path = try Builtins.extractPath(v)
            return .string(try String(contentsOfFile: path, encoding: .utf8))
        }
        set(b, "readDir") { v in
            let path = try Builtins.extractPath(v)
            let fm = FileManager.default
            let entries = try fm.contentsOfDirectory(atPath: path)
            let result = AttrSetVal()
            for entry in entries {
                let fullPath = (path as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                result.set(entry, value: .string(isDir.boolValue ? "directory" : "regular"))
            }
            return .attrSet(result)
        }
        set(b, "pathExists") { v in
            let path = try Builtins.extractPath(v)
            return .bool(FileManager.default.fileExists(atPath: path))
        }
        set(b, "import") { v in
            let path = try Builtins.extractPath(v)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let resolvedPath: String
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                resolvedPath = (path as NSString).appendingPathComponent("default.nix")
            } else {
                resolvedPath = path
            }
            let env = Builtins.baseEnv(evaluator: evaluator)
            return try evaluator.evalFile(resolvedPath, env: env)
        }

        // --- Error / debug ---
        set(b, "throw") { v in
            guard case .string(let msg) = v else { throw EvalError(message: "builtins.throw: expected string") }
            throw EvalError(message: msg)
        }
        set(b, "abort") { v in
            guard case .string(let msg) = v else { throw EvalError(message: "builtins.abort: expected string") }
            throw EvalError(message: "evaluation aborted: \(msg)")
        }
        set(b, "trace") { v in
            let msg = try evaluator.coerceToString(v)
            return .builtin("trace") { v2 in
                FileHandle.standardError.write(Data("trace: \(msg)\n".utf8))
                return v2
            }
        }
        set(b, "tryEval") { v in
            // tryEval doesn't quite work as a builtin since it needs to catch
            // errors from evaluating a thunk. Best-effort: just wrap the value.
            let result = AttrSetVal()
            result.set("success", value: .bool(true))
            result.set("value", value: v)
            return .attrSet(result)
        }
        set(b, "seq") { _ in .builtin("seq") { v2 in v2 } }
        set(b, "deepSeq") { _ in .builtin("deepSeq") { v2 in v2 } }

        // --- Fetch stubs ---
        set(b, "fetchGit") { _ in throw EvalError(message: "builtins.fetchGit: not implemented (stub)") }
        set(b, "fetchTarball") { _ in throw EvalError(message: "builtins.fetchTarball: not implemented (stub)") }
        set(b, "fetchurl") { _ in throw EvalError(message: "builtins.fetchurl: not implemented (stub)") }
        set(b, "getFlake") { _ in throw EvalError(message: "builtins.getFlake: not implemented (stub)") }

        // --- Constants ---
        b.set("currentSystem", value: .string(currentSystem()))
        b.set("storeDir", value: .string("/nix/store"))
        b.set("nixVersion", value: .string("2.24.0-swix"))
        b.set("langVersion", value: .int(6))
        b.set("true", value: .bool(true))
        b.set("false", value: .bool(false))
        b.set("null", value: .null)

        let builtinsVal = Value.attrSet(b)

        // Top-level env
        var top: [String: Value] = [:]
        top["builtins"] = builtinsVal
        top["true"] = .bool(true)
        top["false"] = .bool(false)
        top["null"] = .null
        top["map"] = .builtin("map") { fn in .builtin("map") { v2 in
            guard case .list(let l) = v2 else { throw EvalError(message: "map: expected list") }
            return .list(try l.map { try Builtins.applyFn(fn, arg: $0, evaluator: evaluator) })
        }}
        top["throw"] = .builtin("throw") { v in
            guard case .string(let m) = v else { throw EvalError(message: "throw: expected string") }
            throw EvalError(message: m)
        }
        top["abort"] = .builtin("abort") { v in
            guard case .string(let m) = v else { throw EvalError(message: "abort: expected string") }
            throw EvalError(message: "aborted: \(m)")
        }
        top["toString"] = .builtin("toString") { v in .string(try evaluator.coerceToString(v)) }
        top["import"] = .builtin("import") { v in
            let path = try Builtins.extractPath(v)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let resolvedPath: String
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                resolvedPath = (path as NSString).appendingPathComponent("default.nix")
            } else {
                resolvedPath = path
            }
            let env = Builtins.baseEnv(evaluator: evaluator)
            return try evaluator.evalFile(resolvedPath, env: env)
        }
        top["baseNameOf"] = .builtin("baseNameOf") { v in
            guard case .string(let s) = v else { throw EvalError(message: "baseNameOf: expected string") }
            return .string((s as NSString).lastPathComponent)
        }
        top["dirOf"] = .builtin("dirOf") { v in
            switch v {
            case .string(let s): return .string((s as NSString).deletingLastPathComponent)
            case .path(let p): return .path((p as NSString).deletingLastPathComponent)
            default: throw EvalError(message: "dirOf: expected string or path")
            }
        }
        top["removeAttrs"] = .builtin("removeAttrs") { v in
            guard case .attrSet(let s) = v else { throw EvalError(message: "removeAttrs: expected set") }
            return .builtin("removeAttrs") { v2 in
                guard case .list(let names) = v2 else { throw EvalError(message: "removeAttrs: expected list") }
                let toRemove = Set(names.compactMap { v -> String? in
                    if case .string(let n) = v { return n }; return nil
                })
                let result = AttrSetVal()
                for key in s.keys where !toRemove.contains(key) {
                    result.set(key, value: try s.force(key, evaluator: evaluator))
                }
                return .attrSet(result)
            }
        }
        top["isNull"] = .builtin("isNull") { v in
            if case .null = v { return .bool(true) }; return .bool(false)
        }

        return Env(bindings: top)
    }

    // MARK: - Helpers

    private static func set(_ s: AttrSetVal, _ name: String, fn: @escaping @Sendable (Value) throws -> Value) {
        s.set(name, value: .builtin(name, fn))
    }

    /// Apply a Value (closure or builtin) to an argument.
    public static func applyFn(_ fn: Value, arg: Value, evaluator: Evaluator) throws -> Value {
        switch fn {
        case .closure(let c): return try evaluator.applyClosure(c, arg: arg)
        case .builtin(_, let f): return try f(arg)
        default: throw EvalError(message: "expected function, got \(fn)")
        }
    }

    static func extractPath(_ v: Value) throws -> String {
        switch v {
        case .path(let p): return p
        case .string(let s): return s
        default: throw EvalError(message: "expected path or string, got \(v)")
        }
    }

    static func valuesEqual(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.float(let x), .float(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public static func currentSystem() -> String {
        #if arch(arm64)
        let arch = "aarch64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        #if os(macOS)
        let os = "darwin"
        #elseif os(Linux)
        let os = "linux"
        #else
        let os = "unknown"
        #endif
        return "\(arch)-\(os)"
    }

    // MARK: - JSON

    static func valueToJSON(_ v: Value, evaluator: Evaluator) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: try valueToJSONObj(v, evaluator: evaluator), options: [.sortedKeys, .fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "null"
    }

    static func valueToJSONObj(_ v: Value, evaluator: Evaluator) throws -> Any {
        switch v {
        case .int(let n): return NSNumber(value: n)
        case .float(let f): return NSNumber(value: f)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        case .string(let s): return s
        case .list(let l): return try l.map { try valueToJSONObj($0, evaluator: evaluator) }
        case .attrSet(let s):
            var dict: [String: Any] = [:]
            for key in s.keys.sorted() {
                dict[key] = try valueToJSONObj(s.force(key, evaluator: evaluator), evaluator: evaluator)
            }
            return dict
        case .path(let p): return p
        case .closure, .builtin: throw EvalError(message: "cannot convert function to JSON")
        }
    }

    static func jsonToValue(_ json: String) throws -> Value {
        guard let data = json.data(using: .utf8) else {
            throw EvalError(message: "builtins.fromJSON: invalid UTF-8")
        }
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return jsonObjToValue(obj)
    }

    static func jsonObjToValue(_ obj: Any) -> Value {
        switch obj {
        case let n as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return .bool(n.boolValue)
            }
            if n.objCType.pointee == 0x64 /* 'd' */ {
                return .float(n.doubleValue)
            }
            return .int(n.int64Value)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .list(a.map { jsonObjToValue($0) })
        case let d as [String: Any]:
            let set = AttrSetVal()
            for (k, v) in d { set.set(k, value: jsonObjToValue(v)) }
            return .attrSet(set)
        case is NSNull:
            return .null
        default:
            return .null
        }
    }
}
