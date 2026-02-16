// Lexer.swift - Streaming Nix Lexer

/// Token kinds
public enum TokenKind: Sendable, Equatable {
    // Literals
    case int(Int64)
    case float(Double)
    case stringStart        // opening "
    case stringText(String) // literal text within string
    case interpStart        // ${
    case interpEnd          // } closing interpolation
    case stringEnd          // closing "
    case indStringStart     // opening ''
    case indStringText(String)
    case indStringEnd       // closing ''
    case path(String)
    case identifier(String)

    // Keywords
    case kwLet, kwIn, kwIf, kwThen, kwElse
    case kwWith, kwRec, kwInherit, kwAssert
    case kwTrue, kwFalse, kwNull
    case kwOr             // or (used as keyword in some contexts)

    // Operators
    case plus, minus, star, slash
    case plusPlus           // ++
    case slashSlash         // //
    case eqEq, bangEq       // == !=
    case lt, gt, lte, gte    // < > <= >=
    case ampAmp, pipePipe    // && ||
    case bang               // !
    case arrow              // ->
    case questionMark       // ?

    // Punctuation
    case lBrace, rBrace     // { }
    case lBracket, rBracket // [ ]
    case lParen, rParen     // ( )
    case semicolon          // ;
    case colon              // :
    case dot                // .
    case eq                 // =
    case at                 // @
    case comma              // ,
    case ellipsis           // ...

    case eof
}

public struct Token: Sendable, Equatable {
    public var kind: TokenKind
    public var span: Span

    public init(kind: TokenKind, span: Span) {
        self.kind = kind
        self.span = span
    }
}

/// Lexer error
public struct LexerError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var location: SourceLocation
    public var description: String { "\(location): \(message)" }

    public init(message: String, location: SourceLocation) {
        self.message = message
        self.location = location
    }
}

/// Streaming lexer for Nix source code.
/// Operates on UTF-8 bytes, supports string interpolation via a mode stack.
public struct Lexer: Sendable {
    private var source: [UInt8]
    private var pos: Int
    private var location: SourceLocation
    private var modeStack: [LexMode]
    /// Track brace depth per interpolation level so we know when `}` closes an interpolation.
    private var braceDepth: [Int]

    enum LexMode: Sendable {
        case normal
        case inString
        case inIndentedString
    }

    // MARK: - Keyword map

    private static let keywords: [String: TokenKind] = [
        "let": .kwLet, "in": .kwIn, "if": .kwIf, "then": .kwThen, "else": .kwElse,
        "with": .kwWith, "rec": .kwRec, "inherit": .kwInherit, "assert": .kwAssert,
        "true": .kwTrue, "false": .kwFalse, "null": .kwNull,
        "or": .kwOr,
    ]

    // MARK: - Init

    public init(source: String) {
        self.source = Array(source.utf8)
        self.pos = 0
        self.location = SourceLocation(offset: 0, line: 1, column: 1)
        self.modeStack = [.normal]
        self.braceDepth = []
    }

    // MARK: - Character helpers

    private func peek() -> UInt8? {
        pos < source.count ? source[pos] : nil
    }

    private func peekAt(offset: Int) -> UInt8? {
        let idx = pos + offset
        return idx < source.count ? source[idx] : nil
    }

    @discardableResult
    private mutating func advance() -> UInt8? {
        guard pos < source.count else { return nil }
        let byte = source[pos]
        pos += 1
        if byte == UInt8(ascii: "\n") {
            location.line += 1
            location.column = 1
        } else {
            location.column += 1
        }
        location.offset = pos
        return byte
    }

    private mutating func advance(_ n: Int) {
        for _ in 0..<n {
            advance()
        }
    }

    private var currentMode: LexMode {
        modeStack.last ?? .normal
    }

    // MARK: - Public API

    /// Return the next token from the source. Throws `LexerError` on invalid input.
    public mutating func nextToken() throws -> Token {
        switch currentMode {
        case .normal:
            return try lexNormal()
        case .inString:
            return try lexString()
        case .inIndentedString:
            return try lexIndentedString()
        }
    }

    // MARK: - Normal mode

    private mutating func lexNormal() throws -> Token {
        skipWhitespaceAndComments()

        let start = location

        guard let byte = peek() else {
            return Token(kind: .eof, span: Span(start: start, end: location))
        }

        // Double-quoted string start
        if byte == UInt8(ascii: "\"") {
            advance()
            modeStack.append(.inString)
            return Token(kind: .stringStart, span: Span(start: start, end: location))
        }

        // Indented string start: ''
        if byte == UInt8(ascii: "'"), peekAt(offset: 1) == UInt8(ascii: "'") {
            // Make sure it's not '''  which would be an escape inside indented string
            // At normal level, '' always starts an indented string
            advance(2)
            modeStack.append(.inIndentedString)
            return Token(kind: .indStringStart, span: Span(start: start, end: location))
        }

        // Numbers
        if isDigit(byte) {
            return try lexNumber(start: start)
        }

        // Identifiers / keywords
        if isIdentStart(byte) {
            return lexIdentifierOrKeyword(start: start)
        }

        // Paths: ./  ../  /  ~/
        if isPathStart() {
            return lexPath(start: start)
        }

        // Operators and punctuation
        return try lexOperatorOrPunct(start: start)
    }

    // MARK: - Whitespace and comments

    private mutating func skipWhitespaceAndComments() {
        while let byte = peek() {
            if isWhitespace(byte) {
                advance()
                continue
            }
            // Line comment: # to end of line
            if byte == UInt8(ascii: "#") {
                advance() // skip #
                while let b = peek(), b != UInt8(ascii: "\n") {
                    advance()
                }
                continue
            }
            // Block comment: /* ... */
            if byte == UInt8(ascii: "/"), peekAt(offset: 1) == UInt8(ascii: "*") {
                advance(2) // skip /*
                var depth = 1
                while depth > 0 {
                    guard let b = peek() else { break }
                    if b == UInt8(ascii: "/"), peekAt(offset: 1) == UInt8(ascii: "*") {
                        advance(2)
                        depth += 1
                    } else if b == UInt8(ascii: "*"), peekAt(offset: 1) == UInt8(ascii: "/") {
                        advance(2)
                        depth -= 1
                    } else {
                        advance()
                    }
                }
                continue
            }
            break
        }
    }

    // MARK: - Number lexing

    private mutating func lexNumber(start: SourceLocation) throws -> Token {
        var isFloat = false
        // Consume digits
        while let b = peek(), isDigit(b) {
            advance()
        }
        // Check for decimal point (but not `..` which would be something else, and not `./` which is a path)
        if peek() == UInt8(ascii: "."), let next = peekAt(offset: 1), isDigit(next) {
            isFloat = true
            advance() // skip .
            while let b = peek(), isDigit(b) {
                advance()
            }
        }
        // Exponent
        if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            isFloat = true
            advance() // skip e/E
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                advance()
            }
            while let b = peek(), isDigit(b) {
                advance()
            }
        }

        let text = String(decoding: source[start.offset..<pos], as: UTF8.self)
        let span = Span(start: start, end: location)

        if isFloat {
            guard let value = Double(text) else {
                throw LexerError(message: "invalid float literal: \(text)", location: start)
            }
            return Token(kind: .float(value), span: span)
        } else {
            guard let value = Int64(text) else {
                throw LexerError(message: "invalid integer literal: \(text)", location: start)
            }
            return Token(kind: .int(value), span: span)
        }
    }

    // MARK: - Identifier / keyword

    private mutating func lexIdentifierOrKeyword(start: SourceLocation) -> Token {
        while let b = peek(), isIdentContinue(b) {
            advance()
        }
        let text = String(decoding: source[start.offset..<pos], as: UTF8.self)
        let span = Span(start: start, end: location)
        if let kw = Self.keywords[text] {
            return Token(kind: kw, span: span)
        }
        return Token(kind: .identifier(text), span: span)
    }

    // MARK: - Path lexing

    /// Check if we're at the start of a path.
    /// Paths: `./...`, `../...`, `/...` (absolute), `~/...`
    /// We need to be careful not to confuse `/` (division) or `//` (update) with path starts.
    /// Heuristic: `/` alone followed by an ident-like char is a path only if it looks like an absolute path.
    /// For simplicity: `./`, `../`, `~/` are unambiguous path starts.
    /// Absolute paths `/foo` are trickier—Nix treats bare `/` followed by path chars as a path.
    private func isPathStart() -> Bool {
        guard let byte = peek() else { return false }

        // ./ or ../
        if byte == UInt8(ascii: ".") {
            if peekAt(offset: 1) == UInt8(ascii: "/") { return true }
            if peekAt(offset: 1) == UInt8(ascii: "."), peekAt(offset: 2) == UInt8(ascii: "/") { return true }
            return false
        }

        // ~/
        if byte == UInt8(ascii: "~"), peekAt(offset: 1) == UInt8(ascii: "/") {
            return true
        }

        return false
    }

    private mutating func lexPath(start: SourceLocation) -> Token {
        // Consume path characters: [a-zA-Z0-9._\-+/]
        while let b = peek(), isPathChar(b) {
            advance()
        }
        let text = String(decoding: source[start.offset..<pos], as: UTF8.self)
        return Token(kind: .path(text), span: Span(start: start, end: location))
    }

    // MARK: - Operator / punctuation

    private mutating func lexOperatorOrPunct(start: SourceLocation) throws -> Token {
        let byte = peek()!

        switch byte {
        case UInt8(ascii: "+"):
            advance()
            if peek() == UInt8(ascii: "+") {
                advance()
                return Token(kind: .plusPlus, span: Span(start: start, end: location))
            }
            return Token(kind: .plus, span: Span(start: start, end: location))

        case UInt8(ascii: "-"):
            advance()
            if peek() == UInt8(ascii: ">") {
                advance()
                return Token(kind: .arrow, span: Span(start: start, end: location))
            }
            return Token(kind: .minus, span: Span(start: start, end: location))

        case UInt8(ascii: "*"):
            advance()
            return Token(kind: .star, span: Span(start: start, end: location))

        case UInt8(ascii: "/"):
            advance()
            if peek() == UInt8(ascii: "/") {
                advance()
                return Token(kind: .slashSlash, span: Span(start: start, end: location))
            }
            return Token(kind: .slash, span: Span(start: start, end: location))

        case UInt8(ascii: "="):
            advance()
            if peek() == UInt8(ascii: "=") {
                advance()
                return Token(kind: .eqEq, span: Span(start: start, end: location))
            }
            return Token(kind: .eq, span: Span(start: start, end: location))

        case UInt8(ascii: "!"):
            advance()
            if peek() == UInt8(ascii: "=") {
                advance()
                return Token(kind: .bangEq, span: Span(start: start, end: location))
            }
            return Token(kind: .bang, span: Span(start: start, end: location))

        case UInt8(ascii: "<"):
            advance()
            if peek() == UInt8(ascii: "=") {
                advance()
                return Token(kind: .lte, span: Span(start: start, end: location))
            }
            return Token(kind: .lt, span: Span(start: start, end: location))

        case UInt8(ascii: ">"):
            advance()
            if peek() == UInt8(ascii: "=") {
                advance()
                return Token(kind: .gte, span: Span(start: start, end: location))
            }
            return Token(kind: .gt, span: Span(start: start, end: location))

        case UInt8(ascii: "&"):
            advance()
            if peek() == UInt8(ascii: "&") {
                advance()
                return Token(kind: .ampAmp, span: Span(start: start, end: location))
            }
            throw LexerError(message: "unexpected character '&'", location: start)

        case UInt8(ascii: "|"):
            advance()
            if peek() == UInt8(ascii: "|") {
                advance()
                return Token(kind: .pipePipe, span: Span(start: start, end: location))
            }
            throw LexerError(message: "unexpected character '|'", location: start)

        case UInt8(ascii: "?"):
            advance()
            return Token(kind: .questionMark, span: Span(start: start, end: location))

        case UInt8(ascii: "{"):
            advance()
            // Track brace depth for interpolation
            if !braceDepth.isEmpty {
                braceDepth[braceDepth.count - 1] += 1
            }
            return Token(kind: .lBrace, span: Span(start: start, end: location))

        case UInt8(ascii: "}"):
            advance()
            // Check if this closes an interpolation
            if !braceDepth.isEmpty {
                if braceDepth[braceDepth.count - 1] == 0 {
                    // This closes the interpolation — pop back to string mode
                    braceDepth.removeLast()
                    _ = modeStack.removeLast() // remove the .normal we pushed
                    return Token(kind: .interpEnd, span: Span(start: start, end: location))
                } else {
                    braceDepth[braceDepth.count - 1] -= 1
                }
            }
            return Token(kind: .rBrace, span: Span(start: start, end: location))

        case UInt8(ascii: "["):
            advance()
            return Token(kind: .lBracket, span: Span(start: start, end: location))

        case UInt8(ascii: "]"):
            advance()
            return Token(kind: .rBracket, span: Span(start: start, end: location))

        case UInt8(ascii: "("):
            advance()
            return Token(kind: .lParen, span: Span(start: start, end: location))

        case UInt8(ascii: ")"):
            advance()
            return Token(kind: .rParen, span: Span(start: start, end: location))

        case UInt8(ascii: ";"):
            advance()
            return Token(kind: .semicolon, span: Span(start: start, end: location))

        case UInt8(ascii: ":"):
            advance()
            return Token(kind: .colon, span: Span(start: start, end: location))

        case UInt8(ascii: "."):
            advance()
            if peek() == UInt8(ascii: "."), peekAt(offset: 1) == UInt8(ascii: ".") {
                advance(2)
                return Token(kind: .ellipsis, span: Span(start: start, end: location))
            }
            return Token(kind: .dot, span: Span(start: start, end: location))

        case UInt8(ascii: "@"):
            advance()
            return Token(kind: .at, span: Span(start: start, end: location))

        case UInt8(ascii: ","):
            advance()
            return Token(kind: .comma, span: Span(start: start, end: location))

        default:
            advance()
            let ch = Character(UnicodeScalar(byte))
            throw LexerError(message: "unexpected character '\(ch)'", location: start)
        }
    }

    // MARK: - String mode (double-quoted)

    private mutating func lexString() throws -> Token {
        let start = location

        // Check for end of string
        if peek() == UInt8(ascii: "\"") {
            advance()
            _ = modeStack.removeLast()
            return Token(kind: .stringEnd, span: Span(start: start, end: location))
        }

        // Check for interpolation start
        if peek() == UInt8(ascii: "$"), peekAt(offset: 1) == UInt8(ascii: "{") {
            advance(2)
            modeStack.append(.normal)
            braceDepth.append(0)
            return Token(kind: .interpStart, span: Span(start: start, end: location))
        }

        // Collect string text
        var text: [UInt8] = []
        while let byte = peek() {
            // End of string
            if byte == UInt8(ascii: "\"") {
                break
            }
            // Interpolation
            if byte == UInt8(ascii: "$"), peekAt(offset: 1) == UInt8(ascii: "{") {
                break
            }
            // Escape sequences
            if byte == UInt8(ascii: "\\") {
                advance() // skip backslash
                guard let escaped = peek() else {
                    throw LexerError(message: "unexpected end of string after backslash", location: location)
                }
                switch escaped {
                case UInt8(ascii: "\\"): text.append(UInt8(ascii: "\\")); advance()
                case UInt8(ascii: "\""): text.append(UInt8(ascii: "\"")); advance()
                case UInt8(ascii: "n"):  text.append(UInt8(ascii: "\n")); advance()
                case UInt8(ascii: "r"):  text.append(UInt8(ascii: "\r")); advance()
                case UInt8(ascii: "t"):  text.append(UInt8(ascii: "\t")); advance()
                case UInt8(ascii: "$"):
                    text.append(UInt8(ascii: "$"))
                    advance()
                default:
                    // Nix passes through unknown escapes as-is (backslash + char)
                    text.append(UInt8(ascii: "\\"))
                    text.append(escaped)
                    advance()
                }
                continue
            }
            // Regular character
            text.append(byte)
            advance()
        }

        if text.isEmpty {
            // If we ended up with no text but didn't hit " or ${, we're at EOF inside a string
            if peek() == nil {
                throw LexerError(message: "unterminated string literal", location: start)
            }
        }

        let str = String(decoding: text, as: UTF8.self)
        return Token(kind: .stringText(str), span: Span(start: start, end: location))
    }

    // MARK: - Indented string mode ('')

    private mutating func lexIndentedString() throws -> Token {
        let start = location

        // Check for end: '' (but not ''$ or ''\ or ''\n which are escapes)
        if peek() == UInt8(ascii: "'"), peekAt(offset: 1) == UInt8(ascii: "'") {
            // Check for escape sequences: ''$ ''\ ''\n ''\r ''\t '''
            if let third = peekAt(offset: 2) {
                if third == UInt8(ascii: "$") || third == UInt8(ascii: "\\") {
                    // This is an escape, not end — fall through to text collection
                } else if third == UInt8(ascii: "'") {
                    // ''' is an escaped single quote — fall through to text collection
                } else {
                    // '' followed by something else — this is the end
                    advance(2)
                    _ = modeStack.removeLast()
                    return Token(kind: .indStringEnd, span: Span(start: start, end: location))
                }
            } else {
                // '' at end of input — close
                advance(2)
                _ = modeStack.removeLast()
                return Token(kind: .indStringEnd, span: Span(start: start, end: location))
            }
        }

        // Check for interpolation start
        if peek() == UInt8(ascii: "$"), peekAt(offset: 1) == UInt8(ascii: "{") {
            advance(2)
            modeStack.append(.normal)
            braceDepth.append(0)
            return Token(kind: .interpStart, span: Span(start: start, end: location))
        }

        // Collect indented string text
        var text: [UInt8] = []
        while let byte = peek() {
            // Check for interpolation
            if byte == UInt8(ascii: "$"), peekAt(offset: 1) == UInt8(ascii: "{") {
                break
            }

            // Check for '' sequences
            if byte == UInt8(ascii: "'"), peekAt(offset: 1) == UInt8(ascii: "'") {
                if let third = peekAt(offset: 2) {
                    if third == UInt8(ascii: "$") {
                        // ''$ — escaped $, emit just $
                        advance(3)
                        text.append(UInt8(ascii: "$"))
                        continue
                    } else if third == UInt8(ascii: "\\") {
                        // ''\ followed by an escape char
                        advance(3) // skip '', \
                        guard let escaped = peek() else {
                            throw LexerError(message: "unexpected end of indented string after escape", location: location)
                        }
                        switch escaped {
                        case UInt8(ascii: "n"):  text.append(UInt8(ascii: "\n")); advance()
                        case UInt8(ascii: "r"):  text.append(UInt8(ascii: "\r")); advance()
                        case UInt8(ascii: "t"):  text.append(UInt8(ascii: "\t")); advance()
                        default:
                            text.append(UInt8(ascii: "\\"))
                            text.append(escaped)
                            advance()
                        }
                        continue
                    } else if third == UInt8(ascii: "'") {
                        // ''' — escaped single quote
                        advance(3)
                        text.append(UInt8(ascii: "'"))
                        continue
                    } else {
                        // '' end marker — break out to emit text first
                        break
                    }
                } else {
                    // '' at EOF — break
                    break
                }
            }

            // Regular character
            text.append(byte)
            advance()
        }

        if text.isEmpty && peek() == nil {
            throw LexerError(message: "unterminated indented string literal", location: start)
        }

        let str = String(decoding: text, as: UTF8.self)
        return Token(kind: .indStringText(str), span: Span(start: start, end: location))
    }

    // MARK: - Character classification

    private func isWhitespace(_ b: UInt8) -> Bool {
        b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") ||
        b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r")
    }

    private func isDigit(_ b: UInt8) -> Bool {
        b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")
    }

    private func isIdentStart(_ b: UInt8) -> Bool {
        (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) ||
        (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) ||
        b == UInt8(ascii: "_")
    }

    private func isIdentContinue(_ b: UInt8) -> Bool {
        isIdentStart(b) || isDigit(b) || b == UInt8(ascii: "'") || b == UInt8(ascii: "-")
    }

    private func isPathChar(_ b: UInt8) -> Bool {
        isIdentStart(b) || isDigit(b) ||
        b == UInt8(ascii: "/") || b == UInt8(ascii: ".") ||
        b == UInt8(ascii: "-") || b == UInt8(ascii: "+") ||
        b == UInt8(ascii: "_") || b == UInt8(ascii: "~")
    }
}
