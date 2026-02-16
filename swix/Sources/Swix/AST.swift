// AST.swift - Nix Abstract Syntax Tree

/// Source location tracking
public struct SourceLocation: Sendable, Hashable, CustomStringConvertible {
    public var offset: Int
    public var line: Int
    public var column: Int

    public init(offset: Int = 0, line: Int = 1, column: Int = 1) {
        self.offset = offset
        self.line = line
        self.column = column
    }

    public var description: String { "\(line):\(column)" }
}

public struct Span: Sendable, Hashable {
    public var start: SourceLocation
    public var end: SourceLocation

    public init(start: SourceLocation = .init(), end: SourceLocation = .init()) {
        self.start = start
        self.end = end
    }
}

/// Nix expression AST
public indirect enum Expr: Sendable {
    case int(Int64, Span)
    case float(Double, Span)
    case bool(Bool, Span)
    case null(Span)
    case string(StringExpr, Span)
    case path(String, Span)
    case ident(String, Span)

    case list([Expr], Span)
    case attrSet(AttrSet, Span)
    case select(Expr, [AttrKey], Expr?, Span)  // expr.key1.key2 or expr.key or default
    case hasAttr(Expr, [AttrKey], Span)         // expr ? key

    case letIn([Binding], Expr, Span)
    case with(Expr, Expr, Span)
    case ifThenElse(Expr, Expr, Expr, Span)
    case assert(Expr, Expr, Span)

    case lambda(LambdaParam, Expr, Span)
    case apply(Expr, Expr, Span)

    case unaryNot(Expr, Span)
    case unaryNeg(Expr, Span)
    case binary(BinaryOp, Expr, Expr, Span)
}

/// String expression with interpolation segments
public struct StringExpr: Sendable {
    public enum Segment: Sendable {
        case text(String)
        case interp(Expr)
    }
    public var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments
    }
}

/// Attribute set binding
public struct Binding: Sendable {
    public var path: [AttrKey]
    public var value: Expr
    public var span: Span

    public init(path: [AttrKey], value: Expr, span: Span) {
        self.path = path
        self.value = value
        self.span = span
    }
}

/// Attribute key (can be identifier or dynamic string)
public enum AttrKey: Sendable, Hashable {
    case ident(String)
    case string(String) // for quoted keys
}

/// Attribute set
public struct AttrSet: Sendable {
    public var isRec: Bool
    public var bindings: [Binding]
    public var inherits: [InheritClause]

    public init(isRec: Bool = false, bindings: [Binding] = [], inherits: [InheritClause] = []) {
        self.isRec = isRec
        self.bindings = bindings
        self.inherits = inherits
    }
}

/// Inherit clause
public struct InheritClause: Sendable {
    public var from: Expr?  // inherit (expr) a b c;
    public var attrs: [AttrKey]
    public var span: Span

    public init(from: Expr? = nil, attrs: [AttrKey], span: Span) {
        self.from = from
        self.attrs = attrs
        self.span = span
    }
}

/// Lambda parameter
public enum LambdaParam: Sendable {
    case ident(String)
    case pattern(PatternParam)
}

/// Destructuring pattern parameter
public struct PatternParam: Sendable {
    public struct Field: Sendable {
        public var name: String
        public var defaultValue: Expr?

        public init(name: String, defaultValue: Expr? = nil) {
            self.name = name
            self.defaultValue = defaultValue
        }
    }
    public var fields: [Field]
    public var hasEllipsis: Bool
    public var asName: String?  // { a, b } @ name

    public init(fields: [Field] = [], hasEllipsis: Bool = false, asName: String? = nil) {
        self.fields = fields
        self.hasEllipsis = hasEllipsis
        self.asName = asName
    }
}

/// Binary operators with precedence
public enum BinaryOp: Sendable {
    // Arithmetic
    case add, sub, mul, div
    // Comparison
    case eq, neq, lt, gt, lte, gte
    // Logical
    case and, or, impl
    // Nix-specific
    case concat   // ++
    case update    // //

    /// Operator precedence (higher binds tighter)
    public var precedence: Int {
        switch self {
        case .impl: return 1
        case .or: return 2
        case .and: return 3
        case .eq, .neq: return 4
        case .lt, .gt, .lte, .gte: return 5
        case .update: return 6
        case .concat: return 7  // Nix: ++ is NOT right-assoc but we treat it so
        case .add, .sub: return 8
        case .mul, .div: return 9
        }
    }

    /// Whether operator is right-associative
    public var isRightAssociative: Bool {
        switch self {
        case .impl, .concat, .update: return true
        default: return false
        }
    }
}
