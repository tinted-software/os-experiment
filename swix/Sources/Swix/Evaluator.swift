// Evaluator.swift - Nix Expression Evaluator
import Foundation

// MARK: - Runtime Values

/// Runtime value produced by Nix expression evaluation.
public indirect enum Value: Sendable, CustomStringConvertible {
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case null
    case string(String)
    case path(String)
    case list([Value])
    case attrSet(AttrSetVal)
    case closure(ClosureVal)
    case builtin(String, @Sendable (Value) throws -> Value)

    public var description: String {
        switch self {
        case .int(let n): return "\(n)"
        case .float(let f): return "\(f)"
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .string(let s): return "\"\(s)\""
        case .path(let p): return p
        case .list(let elems):
            let inner = elems.map(\.description).joined(separator: " ")
            return "[ \(inner) ]"
        case .attrSet(let a):
            let keys = a.keys.sorted().joined(separator: " ")
            return "{ \(keys) }"
        case .closure: return "«lambda»"
        case .builtin(let name, _): return "«builtin:\(name)»"
        }
    }
}

// MARK: - Closure

/// A captured closure: lambda parameter + body + captured environment.
public final class ClosureVal: @unchecked Sendable {
    public let param: LambdaParam
    public let body: Expr
    public let env: Env

    public init(param: LambdaParam, body: Expr, env: Env) {
        self.param = param
        self.body = body
        self.env = env
    }
}

// MARK: - Lazy Attribute Set

/// A lazy attribute set. Fields are stored as thunks that are forced on first access.
public final class AttrSetVal: @unchecked Sendable {
    enum Thunk {
        case unevaluated(Expr, Env)
        case evaluated(Value)
        case evaluating // cycle detection
    }

    private var fields: [String: Thunk]
    private let lock = NSLock()

    public init() {
        self.fields = [:]
    }

    public init(values: [String: Value]) {
        self.fields = values.mapValues { .evaluated($0) }
    }

    /// Store a lazy thunk.
    public func set(_ key: String, expr: Expr, env: Env) {
        lock.lock()
        defer { lock.unlock() }
        fields[key] = .unevaluated(expr, env)
    }

    /// Store an already-evaluated value.
    public func set(_ key: String, value: Value) {
        lock.lock()
        defer { lock.unlock() }
        fields[key] = .evaluated(value)
    }

    /// Force a thunk, evaluating it if necessary.
    public func force(_ key: String, evaluator: Evaluator) throws -> Value {
        lock.lock()
        guard let thunk = fields[key] else {
            lock.unlock()
            throw EvalError(message: "attribute '\(key)' not found")
        }

        switch thunk {
        case .evaluated(let v):
            lock.unlock()
            return v
        case .evaluating:
            lock.unlock()
            throw EvalError(message: "infinite recursion detected evaluating attribute '\(key)'")
        case .unevaluated(let expr, let env):
            fields[key] = .evaluating
            lock.unlock()
            let val = try evaluator.eval(expr, env: env)
            lock.lock()
            fields[key] = .evaluated(val)
            lock.unlock()
            return val
        }
    }

    /// Check if a key exists.
    public func has(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fields[key] != nil
    }

    /// All keys in the set.
    public var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(fields.keys)
    }

    /// Force all fields and return as dictionary.
    public func toDict(evaluator: Evaluator) throws -> [String: Value] {
        var result: [String: Value] = [:]
        for key in keys {
            result[key] = try force(key, evaluator: evaluator)
        }
        return result
    }

    /// Merge with another attr set (right-biased, like //).
    public func update(with other: AttrSetVal) -> AttrSetVal {
        let result = AttrSetVal()
        lock.lock()
        for (k, v) in fields {
            result.fields[k] = v
        }
        lock.unlock()

        other.lock.lock()
        for (k, v) in other.fields {
            result.fields[k] = v
        }
        other.lock.unlock()
        return result
    }
}

// MARK: - Environment

/// Persistent immutable environment for name lookups.
public class Env: @unchecked Sendable {
    public let bindings: [String: Value]
    public let parent: Env?

    public init(bindings: [String: Value] = [:], parent: Env? = nil) {
        self.bindings = bindings
        self.parent = parent
    }

    public func lookup(_ name: String) -> Value? {
        if let v = bindings[name] { return v }
        return parent?.lookup(name)
    }

    public func extend(_ newBindings: [String: Value]) -> Env {
        Env(bindings: newBindings, parent: self)
    }

    public func extend(_ name: String, _ value: Value) -> Env {
        Env(bindings: [name: value], parent: self)
    }
}

// MARK: - Error

public struct EvalError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { "eval error: \(message)" }

    public init(message: String) {
        self.message = message
    }
}

// MARK: - Evaluator

/// Tree-walking evaluator for Nix expressions.
public struct Evaluator: Sendable {
    public init() {}

    /// Parse and evaluate a Nix expression string.
    public func eval(_ source: String) throws -> Value {
        var parser = Parser(source: source)
        let expr = try parser.parse()
        return try eval(expr, env: Env())
    }

    /// Parse and evaluate a Nix expression string in a given environment.
    public func eval(_ source: String, env: Env) throws -> Value {
        var parser = Parser(source: source)
        let expr = try parser.parse()
        return try eval(expr, env: env)
    }

    /// Evaluate a Nix file, returning its value.
    public func evalFile(_ path: String, env: Env) throws -> Value {
        let url = URL(fileURLWithPath: path)
        let source = try String(contentsOf: url, encoding: .utf8)
        return try eval(source, env: env)
    }

    /// Evaluate an AST expression in the given environment.
    public func eval(_ expr: Expr, env: Env) throws -> Value {
        switch expr {
        // Literals
        case .int(let n, _):
            return .int(n)

        case .float(let f, _):
            return .float(f)

        case .bool(let b, _):
            return .bool(b)

        case .null:
            return .null

        case .string(let strExpr, _):
            return try evalString(strExpr, env: env)

        case .path(let p, _):
            return .path(p)

        // Identifier lookup
        case .ident(let name, _):
            guard let val = env.lookup(name) else {
                throw EvalError(message: "undefined variable '\(name)'")
            }
            return val

        // List
        case .list(let elems, _):
            let vals = try elems.map { try eval($0, env: env) }
            return .list(vals)

        // Attribute set
        case .attrSet(let attrSet, _):
            return try evalAttrSet(attrSet, env: env)

        // Select: expr.key1.key2 (with optional default)
        case .select(let baseExpr, let keys, let defaultExpr, _):
            return try evalSelect(baseExpr, keys: keys, defaultExpr: defaultExpr, env: env)

        // Has-attr: expr ? key
        case .hasAttr(let baseExpr, let keys, _):
            return try evalHasAttr(baseExpr, keys: keys, env: env)

        // Let...in
        case .letIn(let bindings, let body, _):
            return try evalLet(bindings, body: body, env: env)

        // With
        case .with(let nsExpr, let body, _):
            return try evalWith(nsExpr, body: body, env: env)

        // If/then/else
        case .ifThenElse(let cond, let thenExpr, let elseExpr, _):
            let condVal = try eval(cond, env: env)
            guard case .bool(let b) = condVal else {
                throw EvalError(message: "if condition must be a boolean, got \(condVal)")
            }
            return try eval(b ? thenExpr : elseExpr, env: env)

        // Assert
        case .assert(let cond, let body, _):
            let condVal = try eval(cond, env: env)
            guard case .bool(true) = condVal else {
                throw EvalError(message: "assertion failed")
            }
            return try eval(body, env: env)

        // Lambda
        case .lambda(let param, let body, _):
            return .closure(ClosureVal(param: param, body: body, env: env))

        // Application
        case .apply(let fnExpr, let argExpr, _):
            return try evalApply(fnExpr, argExpr: argExpr, env: env)

        // Unary operators
        case .unaryNot(let operand, _):
            let val = try eval(operand, env: env)
            guard case .bool(let b) = val else {
                throw EvalError(message: "! operator requires a boolean, got \(val)")
            }
            return .bool(!b)

        case .unaryNeg(let operand, _):
            let val = try eval(operand, env: env)
            switch val {
            case .int(let n): return .int(-n)
            case .float(let f): return .float(-f)
            default: throw EvalError(message: "unary - requires a number, got \(val)")
            }

        // Binary operators
        case .binary(let op, let lhs, let rhs, _):
            return try evalBinary(op, lhs: lhs, rhs: rhs, env: env)
        }
    }

    // MARK: - String evaluation

    private func evalString(_ strExpr: StringExpr, env: Env) throws -> Value {
        var result = ""
        for segment in strExpr.segments {
            switch segment {
            case .text(let t):
                result += t
            case .interp(let expr):
                let val = try eval(expr, env: env)
                result += try coerceToString(val)
            }
        }
        return .string(result)
    }

    /// Coerce a value to string for string interpolation.
    public func coerceToString(_ val: Value) throws -> String {
        switch val {
        case .string(let s): return s
        case .int(let n): return "\(n)"
        case .float(let f): return "\(f)"
        case .path(let p): return p
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        default:
            throw EvalError(message: "cannot coerce \(val) to string")
        }
    }

    // MARK: - Attribute set evaluation

    private func evalAttrSet(_ attrSet: AttrSet, env: Env) throws -> Value {
        let result = AttrSetVal()

        if attrSet.isRec {
            // Recursive: bindings can reference each other.
            // Create a mutable dict for the env that includes the attrset fields.
            var recBindings: [String: Value] = [:]
            let resultVal = Value.attrSet(result)

            // First pass: set up all thunks in a shared env that includes the rec set.
            // We'll create a "rec env" that looks up from the attrset itself.
            // For simple single-key bindings, store as thunks in rec env.
            // For nested attrpaths, we need to handle differently.

            // Collect top-level keys
            for binding in attrSet.bindings {
                if binding.path.count == 1, case .ident(let name) = binding.path[0] {
                    // Will be set as thunk below
                    recBindings[name] = .null // placeholder
                }
            }

            // Create rec env: parent is current env, with rec bindings
            // The trick: each thunk's env will have a lazy reference to the attrset
            let recEnv = env.extend(recBindings)

            // Now set actual thunks using recEnv
            for binding in attrSet.bindings {
                try setBinding(result, path: binding.path, value: binding.value, env: recEnv)
            }

            // Patch recEnv bindings to point to the attrset fields
            // Since Env is immutable, we create a wrapper env that delegates to the attrset
            let attrSetEnv = AttrSetEnv(attrSet: result, evaluator: self, parent: env)
            // Re-set thunks with the proper env
            for binding in attrSet.bindings {
                try setBinding(result, path: binding.path, value: binding.value, env: attrSetEnv)
            }

            // Handle inherits
            for inherit in attrSet.inherits {
                try evalInherit(inherit, into: result, env: attrSetEnv)
            }

            return resultVal

        } else {
            // Non-recursive: thunks close over current env
            for binding in attrSet.bindings {
                try setBinding(result, path: binding.path, value: binding.value, env: env)
            }
            for inherit in attrSet.inherits {
                try evalInherit(inherit, into: result, env: env)
            }
            return .attrSet(result)
        }
    }

    /// Set a binding in an attr set, handling nested paths like `a.b.c = val`.
    private func setBinding(_ attrSet: AttrSetVal, path: [AttrKey], value: Expr, env: Env) throws {
        guard let first = path.first else { return }

        let key = try attrKeyToString(first)

        if path.count == 1 {
            attrSet.set(key, expr: value, env: env)
        } else {
            // Nested path: a.b.c = val -> create intermediate attrsets
            // Check if key already exists as an attrset
            if attrSet.has(key) {
                // For nested merging, we'd need to force and merge.
                // For simplicity, just create nested.
            }
            let nested = AttrSetVal()
            let remaining = Array(path.dropFirst())
            try setBinding(nested, path: remaining, value: value, env: env)
            attrSet.set(key, value: .attrSet(nested))
        }
    }

    private func attrKeyToString(_ key: AttrKey) throws -> String {
        switch key {
        case .ident(let name): return name
        case .string(let s): return s
        }
    }

    private func evalInherit(_ inherit: InheritClause, into attrSet: AttrSetVal, env: Env) throws {
        if let fromExpr = inherit.from {
            // inherit (expr) a b c; — look up attrs from the evaluated expr
            let fromVal = try eval(fromExpr, env: env)
            guard case .attrSet(let fromSet) = fromVal else {
                throw EvalError(message: "inherit source must be an attribute set")
            }
            for attr in inherit.attrs {
                let name = try attrKeyToString(attr)
                let val = try fromSet.force(name, evaluator: self)
                attrSet.set(name, value: val)
            }
        } else {
            // inherit a b c; — look up from env
            for attr in inherit.attrs {
                let name = try attrKeyToString(attr)
                guard let val = env.lookup(name) else {
                    throw EvalError(message: "undefined variable '\(name)' in inherit")
                }
                attrSet.set(name, value: val)
            }
        }
    }

    // MARK: - Select

    private func evalSelect(_ baseExpr: Expr, keys: [AttrKey], defaultExpr: Expr?, env: Env) throws -> Value {
        var current = try eval(baseExpr, env: env)

        for key in keys {
            let keyStr = try attrKeyToString(key)
            guard case .attrSet(let attrSetVal) = current else {
                if let def = defaultExpr {
                    return try eval(def, env: env)
                }
                throw EvalError(message: "cannot select from non-attribute-set value")
            }
            if !attrSetVal.has(keyStr) {
                if let def = defaultExpr {
                    return try eval(def, env: env)
                }
                throw EvalError(message: "attribute '\(keyStr)' not found")
            }
            current = try attrSetVal.force(keyStr, evaluator: self)
        }

        return current
    }

    // MARK: - Has-attr

    private func evalHasAttr(_ baseExpr: Expr, keys: [AttrKey], env: Env) throws -> Value {
        var current = try eval(baseExpr, env: env)

        for key in keys {
            let keyStr = try attrKeyToString(key)
            guard case .attrSet(let attrSetVal) = current else {
                return .bool(false)
            }
            if !attrSetVal.has(keyStr) {
                return .bool(false)
            }
            // Force to get deeper for nested checks
            if keys.last.map({ try? attrKeyToString($0) }) != keyStr {
                current = (try? attrSetVal.force(keyStr, evaluator: self)) ?? .null
            }
        }

        return .bool(true)
    }

    // MARK: - Let

    private func evalLet(_ bindings: [Binding], body: Expr, env: Env) throws -> Value {
        // Let bindings are mutually recursive (like rec attrsets).
        let letSet = AttrSetVal()
        let letEnv = AttrSetEnv(attrSet: letSet, evaluator: self, parent: env)

        for binding in bindings {
            guard binding.path.count == 1 else {
                throw EvalError(message: "nested attribute paths in let bindings are not supported")
            }
            let name = try attrKeyToString(binding.path[0])
            letSet.set(name, expr: binding.value, env: letEnv)
        }

        return try eval(body, env: letEnv)
    }

    // MARK: - With

    private func evalWith(_ nsExpr: Expr, body: Expr, env: Env) throws -> Value {
        let nsVal = try eval(nsExpr, env: env)
        guard case .attrSet(let attrSetVal) = nsVal else {
            throw EvalError(message: "with expression requires an attribute set, got \(nsVal)")
        }

        // Create env where lookups also check the attrset
        let withEnv = AttrSetEnv(attrSet: attrSetVal, evaluator: self, parent: env)
        return try eval(body, env: withEnv)
    }

    // MARK: - Apply

    private func evalApply(_ fnExpr: Expr, argExpr: Expr, env: Env) throws -> Value {
        let fnVal = try eval(fnExpr, env: env)

        switch fnVal {
        case .closure(let closure):
            let argVal = try eval(argExpr, env: env)
            return try applyClosure(closure, arg: argVal)

        case .builtin(_, let fn):
            let argVal = try eval(argExpr, env: env)
            return try fn(argVal)

        default:
            throw EvalError(message: "attempt to call a non-function value: \(fnVal)")
        }
    }

    /// Apply any function value (closure or builtin) to an argument.
    public func applyFunction(_ fn: Value, arg: Value) throws -> Value {
        switch fn {
        case .closure(let closure):
            return try applyClosure(closure, arg: arg)
        case .builtin(_, let bfn):
            return try bfn(arg)
        default:
            throw EvalError(message: "attempt to call a non-function value: \(fn)")
        }
    }

    public func applyClosure(_ closure: ClosureVal, arg: Value) throws -> Value {
        let bodyEnv: Env

        switch closure.param {
        case .ident(let name):
            bodyEnv = closure.env.extend(name, arg)

        case .pattern(let pattern):
            guard case .attrSet(let argSet) = arg else {
                throw EvalError(message: "function expects an attribute set argument, got \(arg)")
            }

            var newBindings: [String: Value] = [:]

            for field in pattern.fields {
                if argSet.has(field.name) {
                    newBindings[field.name] = try argSet.force(field.name, evaluator: self)
                } else if let defaultExpr = field.defaultValue {
                    // Evaluate default in the closure's env extended with bindings so far
                    let defEnv = closure.env.extend(newBindings)
                    newBindings[field.name] = try eval(defaultExpr, env: defEnv)
                } else {
                    throw EvalError(message: "missing required attribute '\(field.name)' in function argument")
                }
            }

            // Check for unexpected attributes if no ellipsis
            if !pattern.hasEllipsis {
                let expected = Set(pattern.fields.map(\.name))
                for key in argSet.keys {
                    if !expected.contains(key) {
                        throw EvalError(message: "unexpected attribute '\(key)' in function argument")
                    }
                }
            }

            // Bind the @name if present
            if let asName = pattern.asName {
                newBindings[asName] = arg
            }

            bodyEnv = closure.env.extend(newBindings)
        }

        return try eval(closure.body, env: bodyEnv)
    }

    // MARK: - Binary operators

    private func evalBinary(_ op: BinaryOp, lhs: Expr, rhs: Expr, env: Env) throws -> Value {
        // Short-circuit for logical operators
        switch op {
        case .and:
            let leftVal = try eval(lhs, env: env)
            guard case .bool(let lb) = leftVal else {
                throw EvalError(message: "&& requires booleans")
            }
            if !lb { return .bool(false) }
            let rightVal = try eval(rhs, env: env)
            guard case .bool(let rb) = rightVal else {
                throw EvalError(message: "&& requires booleans")
            }
            return .bool(rb)

        case .or:
            let leftVal = try eval(lhs, env: env)
            guard case .bool(let lb) = leftVal else {
                throw EvalError(message: "|| requires booleans")
            }
            if lb { return .bool(true) }
            let rightVal = try eval(rhs, env: env)
            guard case .bool(let rb) = rightVal else {
                throw EvalError(message: "|| requires booleans")
            }
            return .bool(rb)

        case .impl:
            let leftVal = try eval(lhs, env: env)
            guard case .bool(let lb) = leftVal else {
                throw EvalError(message: "-> requires booleans")
            }
            if !lb { return .bool(true) }
            let rightVal = try eval(rhs, env: env)
            guard case .bool(let rb) = rightVal else {
                throw EvalError(message: "-> requires booleans")
            }
            return .bool(rb)

        default:
            break
        }

        let leftVal = try eval(lhs, env: env)
        let rightVal = try eval(rhs, env: env)

        switch op {
        // Arithmetic
        case .add:
            return try evalAdd(leftVal, rightVal)
        case .sub:
            return try evalArith(leftVal, rightVal, op: -, fop: -)
        case .mul:
            return try evalArith(leftVal, rightVal, op: *, fop: *)
        case .div:
            return try evalDiv(leftVal, rightVal)

        // List concatenation
        case .concat:
            guard case .list(let l) = leftVal, case .list(let r) = rightVal else {
                throw EvalError(message: "++ requires two lists")
            }
            return .list(l + r)

        // Attribute set update (merge)
        case .update:
            guard case .attrSet(let l) = leftVal, case .attrSet(let r) = rightVal else {
                throw EvalError(message: "// requires two attribute sets")
            }
            return .attrSet(l.update(with: r))

        // Equality
        case .eq:
            return .bool(valuesEqual(leftVal, rightVal))
        case .neq:
            return .bool(!valuesEqual(leftVal, rightVal))

        // Comparisons
        case .lt:
            return .bool(try compareValues(leftVal, rightVal) < 0)
        case .gt:
            return .bool(try compareValues(leftVal, rightVal) > 0)
        case .lte:
            return .bool(try compareValues(leftVal, rightVal) <= 0)
        case .gte:
            return .bool(try compareValues(leftVal, rightVal) >= 0)

        case .and, .or, .impl:
            fatalError("handled above")
        }
    }

    private func evalAdd(_ l: Value, _ r: Value) throws -> Value {
        switch (l, r) {
        case (.int(let a), .int(let b)): return .int(a + b)
        case (.float(let a), .float(let b)): return .float(a + b)
        case (.int(let a), .float(let b)): return .float(Double(a) + b)
        case (.float(let a), .int(let b)): return .float(a + Double(b))
        case (.string(let a), .string(let b)): return .string(a + b)
        case (.path(let a), .string(let b)): return .path(a + "/" + b)
        case (.path(let a), .path(let b)): return .path(a + "/" + b)
        default:
            throw EvalError(message: "cannot add \(l) and \(r)")
        }
    }

    private func evalArith(_ l: Value, _ r: Value,
                           op: (Int64, Int64) -> Int64,
                           fop: (Double, Double) -> Double) throws -> Value {
        switch (l, r) {
        case (.int(let a), .int(let b)): return .int(op(a, b))
        case (.float(let a), .float(let b)): return .float(fop(a, b))
        case (.int(let a), .float(let b)): return .float(fop(Double(a), b))
        case (.float(let a), .int(let b)): return .float(fop(a, Double(b)))
        default:
            throw EvalError(message: "arithmetic requires numbers")
        }
    }

    private func evalDiv(_ l: Value, _ r: Value) throws -> Value {
        switch (l, r) {
        case (.int(_), .int(0)):
            throw EvalError(message: "division by zero")
        case (.int(let a), .int(let b)): return .int(a / b)
        case (.float(let a), .float(let b)): return .float(a / b)
        case (.int(let a), .float(let b)): return .float(Double(a) / b)
        case (.float(let a), .int(let b)): return .float(a / Double(b))
        default:
            throw EvalError(message: "division requires numbers")
        }
    }

    public func valuesEqual(_ l: Value, _ r: Value) -> Bool {
        switch (l, r) {
        case (.int(let a), .int(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.int(let a), .float(let b)): return Double(a) == b
        case (.float(let a), .int(let b)): return a == Double(b)
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.path(let a), .path(let b)): return a == b
        case (.null, .null): return true
        case (.list(let a), .list(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { valuesEqual($0, $1) }
        default: return false
        }
    }

    private func compareValues(_ l: Value, _ r: Value) throws -> Int {
        switch (l, r) {
        case (.int(let a), .int(let b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        case (.float(let a), .float(let b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        case (.int(let a), .float(let b)):
            let fa = Double(a)
            return fa < b ? -1 : (fa > b ? 1 : 0)
        case (.float(let a), .int(let b)):
            let fb = Double(b)
            return a < fb ? -1 : (a > fb ? 1 : 0)
        case (.string(let a), .string(let b)):
            return a < b ? -1 : (a > b ? 1 : 0)
        default:
            throw EvalError(message: "cannot compare \(l) and \(r)")
        }
    }
}

// MARK: - AttrSetEnv

/// Special environment that delegates lookups to an AttrSetVal (for `with`, `rec`, `let`).
final class AttrSetEnv: Env, @unchecked Sendable {
    let attrSet: AttrSetVal
    let evaluator: Evaluator

    init(attrSet: AttrSetVal, evaluator: Evaluator, parent: Env?) {
        self.attrSet = attrSet
        self.evaluator = evaluator
        super.init(bindings: [:], parent: parent)
    }

    override func lookup(_ name: String) -> Value? {
        if attrSet.has(name) {
            return try? attrSet.force(name, evaluator: evaluator)
        }
        return parent?.lookup(name)
    }
}
