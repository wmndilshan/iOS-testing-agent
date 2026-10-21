import Foundation
import SwiftSyntax
import SwiftParser

/// Parses one Swift file and produces its `FileFacts` and `Declaration`s. Deterministic: the same text always
/// yields the same output, and trivia (comments, whitespace) never changes a signature or fingerprint.
public enum SwiftFileIndexer {

    /// `bodies: false` records declarations only (names, signatures, spans), without the per-body call and branch facts. That is enough
    /// to browse a codebase and is several times smaller and faster than the full index the test planner needs.
    public static func index(path: String, module: String, role: FileRole, source: String, bodies: Bool = true) -> (file: FileFacts, declarations: [Declaration]) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let walker = DeclarationWalker(path: path, module: module, converter: converter, collectsBodies: bodies)
        walker.walk(items: tree.statements, context: .topLevel)
        let decls = disambiguate(walker.declarations)
        let file = FileFacts(path: path, module: module, role: role, imports: walker.imports.sorted(), declarations: decls.map(\.id),
                             contentHash: Fingerprint.of(source), lineCount: converter.location(for: tree.endPosition).line,
                             parseErrorCount: ErrorCounter.count(tree))
        return (file, decls)
    }

    /// Overloads with identical selectors get their parameter types appended; exact duplicates (`#if` branches) a counter.
    static func disambiguate(_ decls: [Declaration]) -> [Declaration] {
        var byID = Dictionary(grouping: decls.indices, by: { decls[$0].id })
        var out = decls
        for (id, indices) in byID where indices.count > 1 {
            for i in indices where decls[i].kind.isCallable || decls[i].kind == .property {
                out[i].id = SymbolID(rawValue: id.rawValue + "[" + decls[i].parameters.map(\.type).joined(separator: ",") + "]")
            }
        }
        byID = Dictionary(grouping: out.indices, by: { out[$0].id })
        for (id, indices) in byID where indices.count > 1 {
            for (n, i) in indices.sorted().enumerated() where n > 0 { out[i].id = SymbolID(rawValue: "\(id.rawValue)#\(n + 1)") }
        }
        return out
    }

    /// `any Foo<Bar>?` -> `Foo`; `[Foo]` and function types -> nil (no single receiver type).
    static func baseTypeName(_ type: String) -> String? {
        var t = type.trimmingCharacters(in: .whitespaces)
        for prefix in ["inout ", "any ", "some ", "borrowing ", "consuming ", "sending ", "isolated "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        while let last = t.last, last == "?" || last == "!" { t.removeLast() }
        if t.hasPrefix("("), t.hasSuffix(")"), !t.contains("->") { t = String(t.dropFirst().dropLast()) }
        if let lt = t.firstIndex(of: "<") { t = String(t[..<lt]) }
        guard let first = t.first, first.isLetter || first == "_", !t.contains("->"), !t.contains(" ") else { return nil }
        return t
    }

    /// One-line token rendering without trivia. String literal contents are kept verbatim.
    static func normalize(_ node: Syntax) -> String { render(node.tokens(viewMode: .sourceAccurate)) }

    static func render(_ tokens: some Sequence<TokenSyntax>) -> String {
        var out = ""
        var previous: TokenSyntax?
        var inString = false
        for token in tokens {
            let t = token.text
            let isQuote: Bool = switch token.tokenKind {
            case .stringQuote, .multilineStringQuote, .singleQuote, .rawStringPoundDelimiter: true
            default: false
            }
            if let p = previous, !inString, needsSpace(between: p, and: token) { out += " " }
            out += t
            if isQuote { inString.toggle() }
            previous = token
        }
        return out
    }

    /// Spacing that reads like source: `f(x)`, `a[i]`, `x.y`, `Foo<T>`, `a > b`, `[.a, .b]`, `x?`, `-> (Int)`.
    private static func needsSpace(between p: TokenSyntax, and t: TokenSyntax) -> Bool {
        let prevEndsOperand: Bool = {
            switch p.tokenKind {
            case .identifier, .keyword, .dollarIdentifier, .integerLiteral, .floatLiteral, .rightParen, .rightSquare, .rightAngle,
                 .postfixQuestionMark, .exclamationMark, .stringQuote, .wildcard: return p.tokenKind != .keyword(.return) && p.tokenKind != .keyword(.case) && p.tokenKind != .keyword(.in)
            default: return false
            }
        }()
        switch p.tokenKind {
        case .leftParen, .leftSquare, .leftAngle, .period, .atSign, .pound, .backslash, .prefixOperator: return false
        default: break
        }
        switch t.tokenKind {
        case .rightParen, .rightSquare, .rightAngle, .comma, .colon, .postfixQuestionMark, .exclamationMark, .ellipsis, .postfixOperator, .semicolon: return false
        case .leftAngle: return !prevEndsOperand
        case .period, .leftParen, .leftSquare: return !prevEndsOperand
        default: return true
        }
    }
}

enum ErrorCounter {
    static func count(_ tree: SourceFileSyntax) -> Int {
        guard tree.hasError else { return 0 }
        final class V: SyntaxVisitor {
            var n = 0
            override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind { n += 1; return .skipChildren }
            override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
                if token.presence == .missing { n += 1 }
                return .visitChildren
            }
        }
        let v = V(viewMode: .all)
        v.walk(tree)
        return v.n
    }
}

/// Walks declarations explicitly (not a `SyntaxVisitor`) so the container context is explicit and function bodies are
/// summarized as facts rather than descended into for declarations.
private final class DeclarationWalker {
    struct Context {
        var typePath: [String]
        var container: SymbolID?
        var inProtocol: Bool
        var defaultAccess: AccessLevel
        var maxAccess: AccessLevel
        var extensionContext: String?
        static let topLevel = Context(typePath: [], container: nil, inProtocol: false, defaultAccess: .internal, maxAccess: .open, extensionContext: nil)
    }

    let path: String
    let module: String
    let converter: SourceLocationConverter
    var declarations: [Declaration] = []
    var imports: [String] = []
    private var extensionCounter: [String: Int] = [:]

    private let collectsBodies: Bool

    init(path: String, module: String, converter: SourceLocationConverter, collectsBodies: Bool = true) {
        self.collectsBodies = collectsBodies
        self.path = path; self.module = module; self.converter = converter
    }

    func walk(items: CodeBlockItemListSyntax, context: Context) {
        for item in items {
            if let decl = item.item.as(DeclSyntax.self) { visit(decl, context) }
        }
    }

    func walk(members: MemberBlockItemListSyntax, context: Context) {
        for member in members { visit(member.decl, context) }
    }

    private func visit(_ decl: DeclSyntax, _ ctx: Context) {
        if let d = decl.as(ImportDeclSyntax.self) {
            imports.append(d.path.map(\.name.text).joined(separator: "."))
        } else if let d = decl.as(IfConfigDeclSyntax.self) {
            for clause in d.clauses {
                switch clause.elements {
                case .statements(let items): walk(items: items, context: ctx)
                case .decls(let members): walk(members: members, context: ctx)
                default: break
                }
            }
        } else if let d = decl.as(StructDeclSyntax.self) {
            nominal(d, .struct, d.name.text, d.modifiers, d.attributes, d.inheritanceClause, d.genericParameterClause, d.genericWhereClause, d.memberBlock, ctx)
        } else if let d = decl.as(ClassDeclSyntax.self) {
            nominal(d, .class, d.name.text, d.modifiers, d.attributes, d.inheritanceClause, d.genericParameterClause, d.genericWhereClause, d.memberBlock, ctx)
        } else if let d = decl.as(EnumDeclSyntax.self) {
            nominal(d, .enum, d.name.text, d.modifiers, d.attributes, d.inheritanceClause, d.genericParameterClause, d.genericWhereClause, d.memberBlock, ctx)
        } else if let d = decl.as(ActorDeclSyntax.self) {
            nominal(d, .actor, d.name.text, d.modifiers, d.attributes, d.inheritanceClause, d.genericParameterClause, d.genericWhereClause, d.memberBlock, ctx)
        } else if let d = decl.as(ProtocolDeclSyntax.self) {
            nominal(d, .protocol, d.name.text, d.modifiers, d.attributes, d.inheritanceClause, nil, d.genericWhereClause, d.memberBlock, ctx)
        } else if let d = decl.as(ExtensionDeclSyntax.self) {
            extensionDecl(d, ctx)
        } else if let d = decl.as(FunctionDeclSyntax.self) {
            let params = parameters(d.signature.parameterClause)
            let effects = d.signature.effectSpecifiers
            add(d, name: d.name.text, kind: ctx.container == nil ? .function : .method, selector: selector(d.name.text, params), ctx: ctx,
                modifiers: d.modifiers, attributes: d.attributes, params: params, returnType: d.signature.returnClause?.type.trimmedDescription,
                isAsync: effects?.asyncSpecifier != nil, throwsClause: effects?.throwsClause,
                generics: d.genericParameterClause, whereClause: d.genericWhereClause, body: d.body.map { [Syntax($0)] } ?? [], exclude: d.body.map { [Syntax($0)] } ?? [])
        } else if let d = decl.as(InitializerDeclSyntax.self) {
            let params = parameters(d.signature.parameterClause)
            let effects = d.signature.effectSpecifiers
            add(d, name: "init", kind: .initializer, selector: selector("init", params), ctx: ctx, modifiers: d.modifiers, attributes: d.attributes,
                params: params, returnType: nil, isAsync: effects?.asyncSpecifier != nil, throwsClause: effects?.throwsClause,
                generics: d.genericParameterClause, whereClause: d.genericWhereClause, body: d.body.map { [Syntax($0)] } ?? [], exclude: d.body.map { [Syntax($0)] } ?? [])
        } else if let d = decl.as(DeinitializerDeclSyntax.self) {
            add(d, name: "deinit", kind: .deinitializer, selector: "deinit", ctx: ctx, modifiers: d.modifiers, attributes: d.attributes, params: [],
                returnType: nil, isAsync: false, throwsClause: nil, generics: nil, whereClause: nil, body: d.body.map { [Syntax($0)] } ?? [], exclude: d.body.map { [Syntax($0)] } ?? [])
        } else if let d = decl.as(SubscriptDeclSyntax.self) {
            let params = parameters(d.parameterClause)
            let effects = d.accessorBlock.flatMap { self.accessorEffects($0) }
            add(d, name: "subscript", kind: .subscript, selector: selector("subscript", params), ctx: ctx, modifiers: d.modifiers, attributes: d.attributes,
                params: params, returnType: d.returnClause.type.trimmedDescription, isAsync: effects?.async ?? false, throwsClause: effects?.throwsClause,
                generics: d.genericParameterClause, whereClause: d.genericWhereClause, body: d.accessorBlock.map { [Syntax($0)] } ?? [], exclude: d.accessorBlock.map { [Syntax($0)] } ?? [])
        } else if let d = decl.as(VariableDeclSyntax.self) {
            for binding in d.bindings {
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                var bodies: [Syntax] = []
                if let a = binding.accessorBlock { bodies.append(Syntax(a)) }
                if let i = binding.initializer { bodies.append(Syntax(i)) }
                let effects = binding.accessorBlock.flatMap { accessorEffects($0) }
                // One binding's header: `modifiers attributes let name: Type` (other bindings of the same decl excluded).
                let header = [d.attributes.trimmedDescription, d.modifiers.trimmedDescription, d.bindingSpecifier.text,
                              name + (binding.typeAnnotation.map { ": " + $0.type.trimmedDescription } ?? "")]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                add(d, name: name, kind: .property, selector: name, ctx: ctx, modifiers: d.modifiers, attributes: d.attributes, params: [],
                    returnType: binding.typeAnnotation?.type.trimmedDescription, isAsync: effects?.async ?? false, throwsClause: effects?.throwsClause,
                    generics: nil, whereClause: nil, body: bodies, exclude: [], signatureOverride: collapse(header), spanNode: Syntax(binding))
            }
        } else if let d = decl.as(EnumCaseDeclSyntax.self) {
            for element in d.elements {
                let params = element.parameterClause?.parameters.map {
                    Parameter(label: $0.firstName?.text, name: ($0.secondName ?? $0.firstName)?.text ?? "_", type: $0.type.trimmedDescription, hasDefault: $0.defaultValue != nil)
                } ?? []
                add(d, name: element.name.text, kind: .enumCase, selector: element.name.text, ctx: ctx, modifiers: d.modifiers, attributes: d.attributes,
                    params: params, returnType: nil, isAsync: false, throwsClause: nil, generics: nil, whereClause: nil, body: [], exclude: [],
                    signatureOverride: "case " + collapse(element.trimmedDescription), spanNode: Syntax(element))
            }
        } else if let d = decl.as(TypeAliasDeclSyntax.self) {
            add(d, name: d.name.text, kind: .typeAlias, selector: d.name.text, ctx: ctx, modifiers: d.modifiers, attributes: d.attributes, params: [],
                returnType: d.initializer.value.trimmedDescription, isAsync: false, throwsClause: nil, generics: d.genericParameterClause,
                whereClause: d.genericWhereClause, body: [], exclude: [])
        } else if let d = decl.as(AssociatedTypeDeclSyntax.self) {
            add(d, name: d.name.text, kind: .associatedType, selector: d.name.text, ctx: ctx, modifiers: d.modifiers, attributes: d.attributes, params: [],
                returnType: nil, isAsync: false, throwsClause: nil, generics: nil, whereClause: d.genericWhereClause, body: [], exclude: [],
                inheritance: d.inheritanceClause.map(inherited) ?? [])
        }
    }

    // MARK: Types

    private func nominal(_ decl: some DeclSyntaxProtocol, _ kind: DeclarationKind, _ name: String, _ modifiers: DeclModifierListSyntax,
                         _ attributes: AttributeListSyntax, _ inheritance: InheritanceClauseSyntax?, _ generics: GenericParameterClauseSyntax?,
                         _ whereClause: GenericWhereClauseSyntax?, _ members: MemberBlockSyntax, _ ctx: Context) {
        let path = ctx.typePath + [name]
        let id = SymbolID(rawValue: ([module] + path).joined(separator: "."))
        let access = effectiveAccess(modifiers, ctx)
        add(decl, name: name, kind: kind, selector: name, ctx: ctx, modifiers: modifiers, attributes: attributes, params: [], returnType: nil,
            isAsync: false, throwsClause: nil, generics: generics, whereClause: whereClause, body: [], exclude: [Syntax(members)],
            inheritance: inheritance.map(inherited) ?? [], idOverride: id)
        let inner = Context(typePath: path, container: id, inProtocol: kind == .protocol,
                            defaultAccess: kind == .protocol ? access : min(access, .internal), maxAccess: access, extensionContext: nil)
        walk(members: members.members, context: inner)
    }

    private func extensionDecl(_ d: ExtensionDeclSyntax, _ ctx: Context) {
        let extended = d.extendedType.trimmedDescription
        let conformances = d.inheritanceClause.map(inherited) ?? []
        let n = extensionCounter[extended, default: 0] + 1
        extensionCounter[extended] = n
        let tag = conformances.isEmpty ? "" : ":" + conformances.joined(separator: ",")
        let fileName = (path as NSString).lastPathComponent
        let id = SymbolID(rawValue: "\(module).\(extended){extension\(tag)@\(fileName)\(n > 1 ? "#\(n)" : "")}")
        let explicit = accessModifier(d.modifiers)
        let context = [conformances.isEmpty ? nil : conformances.joined(separator: ", "), d.genericWhereClause.map { SwiftFileIndexer.normalize(Syntax($0)) }]
            .compactMap { $0 }.joined(separator: " ")
        add(d, name: extended, kind: .extension, selector: extended, ctx: ctx, modifiers: d.modifiers, attributes: d.attributes, params: [], returnType: nil,
            isAsync: false, throwsClause: nil, generics: nil, whereClause: d.genericWhereClause, body: [], exclude: [Syntax(d.memberBlock)],
            inheritance: conformances, idOverride: id)
        let container = SymbolID(rawValue: "\(module).\(extended)")
        let inner = Context(typePath: extended.split(separator: ".").map(String.init), container: container, inProtocol: false,
                            defaultAccess: explicit ?? .internal, maxAccess: .open, extensionContext: context.isEmpty ? nil : context)
        walk(members: d.memberBlock.members, context: inner)
    }

    // MARK: Members

    private func add(_ decl: some SyntaxProtocol, name: String, kind: DeclarationKind, selector: String, ctx: Context, modifiers: DeclModifierListSyntax,
                     attributes: AttributeListSyntax, params: [Parameter], returnType: String?, isAsync: Bool, throwsClause: ThrowsClauseSyntax?,
                     generics: GenericParameterClauseSyntax?, whereClause: GenericWhereClauseSyntax?, body: [Syntax], exclude: [Syntax],
                     inheritance: [String] = [], idOverride: SymbolID? = nil, signatureOverride: String? = nil, spanNode: Syntax? = nil) {
        let id = idOverride ?? SymbolID(rawValue: ([module] + ctx.typePath + [selector]).joined(separator: "."))
        let node = spanNode ?? Syntax(decl)
        let start = node.startLocation(converter: converter)
        let end = node.endLocation(converter: converter)
        let attributeNames = attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
        var attributeArguments: [String: String] = [:]
        for a in attributes.compactMap({ $0.as(AttributeSyntax.self) }) where ["Test", "Suite"].contains(a.attributeName.trimmedDescription) {
            attributeArguments[a.attributeName.trimmedDescription] = a.arguments.map { SwiftFileIndexer.normalize(Syntax($0)) } ?? ""
        }
        let signature = signatureOverride ?? header(of: Syntax(decl), excluding: exclude)
        var record = Declaration(
            id: id, name: name, kind: kind, module: module, container: kind == .extension ? nil : ctx.container,
            span: SourceSpan(file: path, line: start.line, column: start.column, endLine: end.line, endColumn: end.column),
            access: kind == .extension ? (accessModifier(modifiers) ?? .internal) : effectiveAccess(modifiers, ctx),
            modifiers: modifiers.filter { $0.detail == nil }.map(\.name.text), attributes: attributeNames,
            isAsync: isAsync, isThrows: throwsClause != nil, typedThrows: throwsClause?.type?.trimmedDescription,
            isStatic: modifiers.contains { ["static", "class"].contains($0.name.text) },
            parameters: params, returnType: returnType,
            genericParameters: generics?.parameters.map(\.name.text) ?? [],
            genericConstraints: constraints(generics, whereClause),
            inheritance: inheritance, signature: signature,
            body: collectsBodies ? BodyFactsCollector.collect(body, converter: converter, parameters: params) : nil,
            extensionContext: kind == .extension ? nil : ctx.extensionContext)
        record.attributeArguments = attributeArguments
        declarations.append(record)
    }

    private func header(of node: Syntax, excluding excluded: [Syntax]) -> String {
        let ranges = excluded.map { $0.position..<$0.endPosition }
        let tokens = node.tokens(viewMode: .sourceAccurate).filter { t in !ranges.contains { $0.contains(t.positionAfterSkippingLeadingTrivia) } }
        return SwiftFileIndexer.render(tokens)
    }

    private func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func parameters(_ clause: FunctionParameterClauseSyntax) -> [Parameter] {
        clause.parameters.map { p in
            let label = p.firstName.text == "_" ? nil : p.firstName.text
            let name = (p.secondName ?? p.firstName).text
            return Parameter(label: label, name: name, type: p.type.trimmedDescription + (p.ellipsis != nil ? "..." : ""), hasDefault: p.defaultValue != nil)
        }
    }

    private func selector(_ name: String, _ params: [Parameter]) -> String {
        "\(name)(" + params.map { ($0.label ?? "_") + ":" }.joined() + ")"
    }

    private func inherited(_ clause: InheritanceClauseSyntax) -> [String] {
        clause.inheritedTypes.map { $0.type.trimmedDescription }
    }

    private func constraints(_ generics: GenericParameterClauseSyntax?, _ whereClause: GenericWhereClauseSyntax?) -> [String] {
        var out = generics?.parameters.compactMap { p in p.inheritedType.map { "\(p.name.text): \($0.trimmedDescription)" } } ?? []
        out += whereClause?.requirements.map { SwiftFileIndexer.normalize(Syntax($0.requirement)) } ?? []
        return out
    }

    private func accessorEffects(_ block: AccessorBlockSyntax) -> (async: Bool, throwsClause: ThrowsClauseSyntax?)? {
        guard case .accessors(let list) = block.accessors else { return nil }
        let effects = list.compactMap(\.effectSpecifiers)
        guard !effects.isEmpty else { return nil }
        return (effects.contains { $0.asyncSpecifier != nil }, effects.lazy.compactMap(\.throwsClause).first)
    }

    private func accessModifier(_ modifiers: DeclModifierListSyntax) -> AccessLevel? {
        // `private(set)` restricts the setter only; it is not the declaration's access level.
        modifiers.lazy.filter { $0.detail == nil }.compactMap { AccessLevel(rawValue: $0.name.text) }.first
    }

    private func effectiveAccess(_ modifiers: DeclModifierListSyntax, _ ctx: Context) -> AccessLevel {
        let own = ctx.inProtocol ? ctx.defaultAccess : (accessModifier(modifiers) ?? ctx.defaultAccess)
        return min(own, ctx.maxAccess)
    }
}
