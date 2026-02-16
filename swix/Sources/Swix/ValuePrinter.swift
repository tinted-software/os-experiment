// ValuePrinter.swift - Pretty-print Nix values
import Foundation

/// Pretty-prints Nix values in Nix-like syntax.
public struct ValuePrinter: Sendable {
    let evaluator: Evaluator

    public init(evaluator: Evaluator = Evaluator()) {
        self.evaluator = evaluator
    }

    /// Pretty-print a value as a Nix expression string.
    public func print(_ value: Value, indent: Int = 0) async -> String {
        switch value {
        case .int(let n):
            return "\(n)"
        case .float(let f):
            return "\(f)"
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .string(let s):
            return "\"\(escapeString(s))\""
        case .path(let p):
            return p
        case .list(let elems):
            if elems.isEmpty { return "[ ]" }
            if elems.count <= 5 && elems.allSatisfy(isSimple) {
                var items: [String] = []
                for item in elems {
                    items.append(await self.print(item))
                }
                return "[ \(items.joined(separator: " ")) ]"
            }
            let pad = String(repeating: "  ", count: indent + 1)
            let endPad = String(repeating: "  ", count: indent)
            var items: [String] = []
            for item in elems {
                items.append("\(pad)\(await self.print(item, indent: indent + 1))")
            }
            return "[\n\(items.joined(separator: "\n"))\n\(endPad)]"
        case .attrSet(let s):
            let keys = s.keys.sorted()
            if keys.isEmpty { return "{ }" }
            let pad = String(repeating: "  ", count: indent + 1)
            let endPad = String(repeating: "  ", count: indent)
            var lines: [String] = []
            for key in keys {
                let val = (try? await s.force(key, evaluator: evaluator)) ?? .string("«error»")
                let valStr = await self.print(val, indent: indent + 1)
                let keyStr = needsQuoting(key) ? "\"\(escapeString(key))\"" : key
                lines.append("\(pad)\(keyStr) = \(valStr);")
            }
            return "{\n\(lines.joined(separator: "\n"))\n\(endPad)}"
        case .closure:
            return "«lambda»"
        case .builtin(let name, _):
            return "«builtin:\(name)»"
        }
    }

    /// Print value as JSON.
    public func printJSON(_ value: Value) async -> String {
        (try? await Builtins.valueToJSON(value, evaluator: evaluator)) ?? "null"
    }

    private func escapeString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\t", with: "\\t")
         .replacingOccurrences(of: "\r", with: "\\r")
    }

    private func needsQuoting(_ key: String) -> Bool {
        guard let first = key.first else { return true }
        if !(first.isLetter || first == "_") { return true }
        return key.contains(where: { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "'") })
    }

    private func isSimple(_ v: Value) -> Bool {
        switch v {
        case .int, .float, .bool, .null, .string, .path: return true
        default: return false
        }
    }
}