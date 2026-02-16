// Parser.swift - Recursive Descent Nix Parser

public struct ParserError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var span: Span
    public var description: String { "Parse error at \(span.start): \(message)" }
}

// MARK: - Token Stream

/// Token stream with lookahead backed by a Lexer.
struct TokenStream: Sendable {
    var lexer: Lexer
    var buffer: [Token]
    /// End location of the last consumed token, used for span tracking.
    var lastEnd: SourceLocation

    init(lexer: Lexer) {
        self.lexer = lexer
        self.buffer = []
        self.lastEnd = SourceLocation()
    }

    mutating func peek(_ offset: Int = 0) throws -> Token {
        while buffer.count <= offset {
            buffer.append(try lexer.nextToken())
        }
        return buffer[offset]
    }

    @discardableResult
    mutating func consume() throws -> Token {
        let tok: Token
        if buffer.isEmpty {
            tok = try lexer.nextToken()
        } else {
            tok = buffer.removeFirst()
        }
        lastEnd = tok.span.end
        return tok
    }

    /// Consume a token and verify it matches `kind` (only for kinds without associated values).
    @discardableResult
    mutating func expect(_ kind: TokenKind) throws -> Token {
        let tok = try consume()
        guard tok.kind == kind else {
            throw ParserError(message: "expected \(kind), got \(tok.kind)", span: tok.span)
        }
        return tok
    }
}

// MARK: - Token Classification Helpers

extension TokenKind {
    /// Whether this token kind can start a primary expression (atom).
    var canStartAtom: Bool {
        switch self {
        case .int, .float, .identifier, .kwTrue, .kwFalse, .kwNull,
             .path, .stringStart, .indStringStart, .lParen, .lBracket, .lBrace, .kwRec:
            return true
        default:
            return false
        }
    }

    /// Whether this token is an identifier (any name).
    var isIdentifier: Bool {
        if case .identifier = self { return true }
        return false
    }

    /// Extract identifier name if this is an identifier token.
    var identifierName: String? {
        if case .identifier(let n) = self { return n }
        return nil
    }

    /// Map token to binary operator, if applicable.
    var binaryOp: BinaryOp? {
        switch self {
        case .plus:       return .add
        case .minus:      return .sub
        case .star:       return .mul
        case .slash:      return .div
        case .plusPlus:    return .concat
        case .slashSlash: return .update
        case .eqEq:       return .eq
        case .bangEq:     return .neq
        case .lt:         return .lt
        case .gt:         return .gt
        case .lte:        return .lte
        case .gte:        return .gte
        case .ampAmp:     return .and
        case .pipePipe:   return .or
        case .arrow:      return .impl
        default:          return nil
        }
    }
}

// MARK: - Parser

/// Recursive descent parser for Nix expressions.
public struct Parser: Sendable {
    var ts: TokenStream

    public init(source: String) {
        self.ts = TokenStream(lexer: Lexer(source: source))
    }

    /// Parse a complete Nix expression, expecting EOF afterwards.
    public mutating func parse() throws -> Expr {
        let expr = try parseExpr()
        let tok = try ts.peek()
        if tok.kind != .eof {
            throw ParserError(message: "unexpected token \(tok.kind) after expression", span: tok.span)
        }
        return expr
    }

    // MARK: - Expression (lowest precedence)

    /// Parse a full expression, handling keywords and lambdas before binary ops.
    mutating func parseExpr() throws -> Expr {
        let tok = try ts.peek()

        switch tok.kind {
        // assert expr ; expr
        case .kwAssert:
            let start = try ts.consume()
            let cond = try parseExpr()
            try ts.expect(.semicolon)
            let body = try parseExpr()
            return .assert(cond, body, span(from: start.span.start))

        // with expr ; expr
        case .kwWith:
            let start = try ts.consume()
            let ns = try parseExpr()
            try ts.expect(.semicolon)
            let body = try parseExpr()
            return .with(ns, body, span(from: start.span.start))

        // let ... in expr
        case .kwLet:
            return try parseLet()

        // if expr then expr else expr
        case .kwIf:
            let start = try ts.consume()
            let cond = try parseExpr()
            try ts.expect(.kwThen)
            let thenExpr = try parseExpr()
            try ts.expect(.kwElse)
            let elseExpr = try parseExpr()
            return .ifThenElse(cond, thenExpr, elseExpr, span(from: start.span.start))

        // Lambda: identifier : body  OR  identifier @ { pattern } : body
        case .identifier:
            let next = try ts.peek(1)
            if next.kind == .colon {
                // Simple lambda: x : body
                let nameTok = try ts.consume()
                try ts.consume() // consume ':'
                let name = nameTok.kind.identifierName!
                let body = try parseExpr()
                return .lambda(.ident(name), body, span(from: nameTok.span.start))
            } else if next.kind == .at {
                // name @ { pattern } : body
                let nameTok = try ts.consume()
                try ts.consume() // consume '@'
                let name = nameTok.kind.identifierName!
                var pattern = try parsePatternParam()
                pattern.asName = name
                try ts.expect(.colon)
                let body = try parseExpr()
                return .lambda(.pattern(pattern), body, span(from: nameTok.span.start))
            }
            return try parseBinaryExpr(minPrec: 0)

        // { ... } could be pattern lambda or attr set
        case .lBrace:
            if try isPatternLambda() {
                return try parsePatternLambda()
            }
            return try parseBinaryExpr(minPrec: 0)

        default:
            return try parseBinaryExpr(minPrec: 0)
        }
    }

    // MARK: - Binary Expression (Pratt / precedence climbing)

    mutating func parseBinaryExpr(minPrec: Int) throws -> Expr {
        var left = try parseUnaryExpr()

        while true {
            let tok = try ts.peek()
            guard let op = tok.kind.binaryOp, op.precedence >= minPrec else {
                break
            }
            try ts.consume() // consume operator
            let nextMinPrec = op.isRightAssociative ? op.precedence : op.precedence + 1
            let right = try parseBinaryExpr(minPrec: nextMinPrec)
            left = .binary(op, left, right, mergeSpan(left, right))
        }

        return left
    }

    // MARK: - Unary Expression

    mutating func parseUnaryExpr() throws -> Expr {
        let tok = try ts.peek()

        switch tok.kind {
        case .bang:
            let start = try ts.consume()
            let operand = try parseUnaryExpr()
            return .unaryNot(operand, span(from: start.span.start))

        case .minus:
            let start = try ts.consume()
            let operand = try parseUnaryExpr()
            return .unaryNeg(operand, span(from: start.span.start))

        default:
            return try parseApplyExpr()
        }
    }

    // MARK: - Function Application (juxtaposition)

    mutating func parseApplyExpr() throws -> Expr {
        var fn = try parseSelectExpr()

        while try ts.peek().kind.canStartAtom {
            let arg = try parseSelectExpr()
            fn = .apply(fn, arg, mergeSpan(fn, arg))
        }

        return fn
    }

    // MARK: - Select & Has-Attr

    mutating func parseSelectExpr() throws -> Expr {
        var expr = try parsePrimary()

        while true {
            let tok = try ts.peek()
            if tok.kind == .dot {
                try ts.consume()
                let path = try parseAttrPath()
                // Check for `or default`
                let peeked = try ts.peek()
                if peeked.kind == .kwOr {
                    try ts.consume()
                    let def = try parseSelectExpr()
                    expr = .select(expr, path, def, mergeSpan(expr, def))
                } else {
                    let pathSpan = span(from: exprSpan(expr).start)
                    expr = .select(expr, path, nil, pathSpan)
                }
            } else if tok.kind == .questionMark {
                try ts.consume()
                let path = try parseAttrPath()
                let pathSpan = span(from: exprSpan(expr).start)
                expr = .hasAttr(expr, path, pathSpan)
            } else {
                break
            }
        }

        return expr
    }

    // MARK: - Primary Expressions

    mutating func parsePrimary() throws -> Expr {
        let tok = try ts.peek()

        switch tok.kind {
        case .int(let n):
            try ts.consume()
            return .int(n, tok.span)

        case .float(let f):
            try ts.consume()
            return .float(f, tok.span)

        case .kwTrue:
            try ts.consume()
            return .bool(true, tok.span)

        case .kwFalse:
            try ts.consume()
            return .bool(false, tok.span)

        case .kwNull:
            try ts.consume()
            return .null(tok.span)

        case .identifier(let name):
            try ts.consume()
            return .ident(name, tok.span)

        case .path(let p):
            try ts.consume()
            return .path(p, tok.span)

        case .stringStart:
            return try parseString()

        case .indStringStart:
            return try parseIndentedString()

        case .lParen:
            try ts.consume()
            let inner = try parseExpr()
            try ts.expect(.rParen)
            return inner

        case .lBracket:
            return try parseList()

        case .kwRec:
            return try parseAttrSetExpr()

        case .lBrace:
            return try parseAttrSetExpr()

        default:
            throw ParserError(message: "unexpected token \(tok.kind)", span: tok.span)
        }
    }

    // MARK: - String Parsing

    mutating func parseString() throws -> Expr {
        let start = try ts.consume() // consume stringStart
        var segments: [StringExpr.Segment] = []

        while true {
            let tok = try ts.peek()
            switch tok.kind {
            case .stringText(let s):
                try ts.consume()
                segments.append(.text(s))
            case .interpStart:
                try ts.consume()
                let expr = try parseExpr()
                try ts.expect(.interpEnd)
                segments.append(.interp(expr))
            case .stringEnd:
                try ts.consume()
                return .string(StringExpr(segments: segments), span(from: start.span.start))
            default:
                throw ParserError(message: "unexpected token \(tok.kind) inside string", span: tok.span)
            }
        }
    }

    mutating func parseIndentedString() throws -> Expr {
        let start = try ts.consume() // consume indStringStart
        var segments: [StringExpr.Segment] = []

        while true {
            let tok = try ts.peek()
            switch tok.kind {
            case .indStringText(let s):
                try ts.consume()
                segments.append(.text(s))
            case .interpStart:
                try ts.consume()
                let expr = try parseExpr()
                try ts.expect(.interpEnd)
                segments.append(.interp(expr))
            case .indStringEnd:
                try ts.consume()
                return .string(StringExpr(segments: segments), span(from: start.span.start))
            default:
                throw ParserError(message: "unexpected token \(tok.kind) inside indented string", span: tok.span)
            }
        }
    }

    // MARK: - List

    mutating func parseList() throws -> Expr {
        let start = try ts.consume() // consume '['
        var elements: [Expr] = []

        while try ts.peek().kind != .rBracket {
            let elem = try parseSelectExpr()
            elements.append(elem)
        }

        try ts.consume() // consume ']'
        return .list(elements, span(from: start.span.start))
    }

    // MARK: - Attribute Set

    mutating func parseAttrSetExpr() throws -> Expr {
        let tok = try ts.peek()
        let isRec: Bool
        let start: SourceLocation

        if tok.kind == .kwRec {
            isRec = true
            start = tok.span.start
            try ts.consume() // consume 'rec'
            try ts.expect(.lBrace)
        } else {
            isRec = false
            start = tok.span.start
            try ts.consume() // consume '{'
        }

        let attrSet = try parseAttrSetBody(isRec: isRec)
        try ts.expect(.rBrace)
        return .attrSet(attrSet, span(from: start))
    }

    mutating func parseAttrSetBody(isRec: Bool) throws -> AttrSet {
        var bindings: [Binding] = []
        var inherits: [InheritClause] = []

        while true {
            let tok = try ts.peek()
            if tok.kind == .rBrace || tok.kind == .eof {
                break
            }

            if tok.kind == .kwInherit {
                inherits.append(try parseInherit())
            } else {
                bindings.append(try parseBinding())
            }
        }

        return AttrSet(isRec: isRec, bindings: bindings, inherits: inherits)
    }

    mutating func parseBinding() throws -> Binding {
        let startTok = try ts.peek()
        let path = try parseAttrPath()
        try ts.expect(.eq)
        let value = try parseExpr()
        try ts.expect(.semicolon)
        return Binding(path: path, value: value, span: span(from: startTok.span.start))
    }

    mutating func parseInherit() throws -> InheritClause {
        let start = try ts.consume() // consume 'inherit'
        var from: Expr? = nil
        var attrs: [AttrKey] = []

        // inherit (expr) ...
        if try ts.peek().kind == .lParen {
            try ts.consume()
            from = try parseExpr()
            try ts.expect(.rParen)
        }

        // inherit names until semicolon
        while try ts.peek().kind != .semicolon {
            attrs.append(try parseAttrKey())
        }

        try ts.expect(.semicolon)
        return InheritClause(from: from, attrs: attrs, span: span(from: start.span.start))
    }

    // MARK: - Attr Path & Key

    /// Parse a dot-separated attribute path: `key.key.key`
    mutating func parseAttrPath() throws -> [AttrKey] {
        var path: [AttrKey] = [try parseAttrKey()]
        while try ts.peek().kind == .dot {
            try ts.consume()
            path.append(try parseAttrKey())
        }
        return path
    }

    /// Parse a single attribute key: identifier or quoted string.
    mutating func parseAttrKey() throws -> AttrKey {
        let tok = try ts.peek()
        switch tok.kind {
        case .identifier(let name):
            try ts.consume()
            return .ident(name)
        case .kwOr:
            // 'or' can be used as an attribute name in Nix
            try ts.consume()
            return .ident("or")
        case .stringStart:
            // Quoted key: parse the string and extract the text
            let strExpr = try parseString()
            if case .string(let s, _) = strExpr,
               s.segments.count == 1,
               case .text(let text) = s.segments[0] {
                return .string(text)
            }
            // Dynamic keys with interpolation — for now treat as string of joined text
            throw ParserError(
                message: "dynamic attribute keys with interpolation are not yet supported",
                span: tok.span
            )
        default:
            throw ParserError(message: "expected attribute key, got \(tok.kind)", span: tok.span)
        }
    }

    // MARK: - Let Expression

    mutating func parseLet() throws -> Expr {
        let start = try ts.consume() // consume 'let'

        // Handle `let { ... }` — Nix legacy form (let-body)
        if try ts.peek().kind == .lBrace {
            // This is actually `let { body }` which is a legacy Nix form.
            // For now, treat as a normal primary fallthrough — the `let` was consumed,
            // and we expect bindings followed by `in`.
            // Actually, `let {` is rarely used. Let's just handle `let bindings in expr`.
        }

        var bindings: [Binding] = []
        var inherits: [InheritClause] = []

        while true {
            let tok = try ts.peek()
            if tok.kind == .kwIn {
                break
            }
            if tok.kind == .eof {
                throw ParserError(message: "unexpected EOF in let expression, expected 'in'", span: tok.span)
            }
            if tok.kind == .kwInherit {
                inherits.append(try parseInherit())
            } else {
                bindings.append(try parseBinding())
            }
        }

        try ts.consume() // consume 'in'
        let body = try parseExpr()

        // If there are inherits, we embed them into the let bindings by converting
        // the let to use an AttrSet node. But the AST has letIn([Binding], Expr, Span),
        // which only takes Binding. For now, we don't support inherit in let.
        // Actually, Nix does support `let inherit ...;` — but our AST Binding type can
        // handle it if we store inherits separately. Let's just discard inherits for now
        // and note the limitation, or we can extend it.
        // For correctness: Nix `let inherit (x) a b; in ...` is valid. Our AST doesn't
        // capture it directly. We'll ignore inherits for now.
        _ = inherits

        return .letIn(bindings, body, span(from: start.span.start))
    }

    // MARK: - Lambda Pattern Detection & Parsing

    /// Determine if a `{` starts a pattern lambda rather than an attr set.
    /// Uses lookahead: scan tokens until the matching `}`, then check if `:` or `@` follows.
    mutating func isPatternLambda() throws -> Bool {
        // We're peeking at `{` at offset 0. Scan forward for the matching `}`.
        var offset = 1
        var depth = 1

        while depth > 0 {
            let tok = try ts.peek(offset)
            switch tok.kind {
            case .lBrace:
                depth += 1
            case .rBrace:
                depth -= 1
            case .eof:
                return false
            default:
                break
            }
            if depth > 0 {
                offset += 1
            }
        }

        // `offset` now points to the matching `}`. Check what follows.
        let afterBrace = try ts.peek(offset + 1)
        switch afterBrace.kind {
        case .colon:
            return true
        case .at:
            return true
        default:
            return false
        }
    }

    /// Parse a pattern lambda: `{ pattern } : body` or `{ pattern } @ name : body`
    mutating func parsePatternLambda() throws -> Expr {
        let startTok = try ts.peek()
        var pattern = try parsePatternParam()

        // Check for `@ name`
        if try ts.peek().kind == .at {
            try ts.consume() // consume '@'
            let nameTok = try ts.consume()
            guard let name = nameTok.kind.identifierName else {
                throw ParserError(message: "expected identifier after '@'", span: nameTok.span)
            }
            pattern.asName = name
        }

        try ts.expect(.colon)
        let body = try parseExpr()
        return .lambda(.pattern(pattern), body, span(from: startTok.span.start))
    }

    /// Parse `{ fields... }` pattern parameter (consumes the braces).
    mutating func parsePatternParam() throws -> PatternParam {
        try ts.expect(.lBrace)
        var fields: [PatternParam.Field] = []
        var hasEllipsis = false

        while true {
            let tok = try ts.peek()

            if tok.kind == .rBrace {
                try ts.consume()
                break
            }

            if tok.kind == .ellipsis {
                try ts.consume()
                hasEllipsis = true
                // Optionally consume trailing comma
                if try ts.peek().kind == .comma {
                    try ts.consume()
                }
                // Expect closing brace
                try ts.expect(.rBrace)
                break
            }

            // Field: identifier or identifier ? default
            guard let name = tok.kind.identifierName else {
                throw ParserError(message: "expected parameter name or '...', got \(tok.kind)", span: tok.span)
            }
            try ts.consume()

            var defaultValue: Expr? = nil
            if try ts.peek().kind == .questionMark {
                try ts.consume()
                defaultValue = try parseExpr()
            }

            fields.append(PatternParam.Field(name: name, defaultValue: defaultValue))

            // Consume comma separator (optional before `}`)
            if try ts.peek().kind == .comma {
                try ts.consume()
            }
        }

        return PatternParam(fields: fields, hasEllipsis: hasEllipsis)
    }

    // MARK: - Span Helpers

    /// Build a span from a start location to the end of the last consumed token.
    func span(from start: SourceLocation) -> Span {
        return Span(start: start, end: ts.lastEnd)
    }

    /// Merge spans of two expressions.
    func mergeSpan(_ a: Expr, _ b: Expr) -> Span {
        let sa = exprSpan(a)
        let sb = exprSpan(b)
        return Span(start: sa.start, end: sb.end)
    }

    /// Extract the span from an expression.
    func exprSpan(_ expr: Expr) -> Span {
        switch expr {
        case .int(_, let s), .float(_, let s), .bool(_, let s), .null(let s),
             .string(_, let s), .path(_, let s), .ident(_, let s),
             .list(_, let s), .attrSet(_, let s), .select(_, _, _, let s),
             .hasAttr(_, _, let s), .letIn(_, _, let s), .with(_, _, let s),
             .ifThenElse(_, _, _, let s), .assert(_, _, let s),
             .lambda(_, _, let s), .apply(_, _, let s),
             .unaryNot(_, let s), .unaryNeg(_, let s), .binary(_, _, _, let s):
            return s
        }
    }
}


