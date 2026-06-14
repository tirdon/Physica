// EquationEntity — a column of equation rows aligned on the '=' glyph.
//
// Each row is its own line of an unfolding derivation (Manim's aligned eqnarray):
// rows after the first may drop the LHS (a continuation `= …`), only the last
// row is editable, and every row's '=' lines up on a shared vertical. Each token
// is a TextEntity carrying its DisplayToken, so a token is independently
// styleable and (in the game) draggable; the provider supplies its glyphs.

@MainActor
public final class EquationRow: Layout {
    public let equation: Equation
    public private(set) var tokens: [DisplayToken]
    public private(set) var tokenEntities: [TextEntity] = []
    public private(set) var isInteractive = false
    /// X (row-local) of the '=' token's center — the column aligns rows on this.
    public private(set) var equalsAnchorX: Real = 0

    private let style: EquationStyle

    init(equation: Equation, tokens: [DisplayToken], provider: TokenGlyphProvider, style: EquationStyle) {
        self.equation = equation
        self.tokens = tokens
        self.style = style
        super.init()
        name = "row"
        for token in tokens {
            let run = provider.glyphs(for: token)
            let entity = TextEntity(glyphs: run.glyphs, fontSize: style.fontSize)
            entity.components[RenderStyleComponent.self] = RenderStyleComponent(
                color: style.color, strokeColor: style.color,
                strokeWidth: 0.012 * style.fontSize, isFilled: true
            )
            entity.shown()
            entity.name = token.value
            entity.components[TokenComponent.self] = TokenComponent(token: token)
            tokenEntities.append(entity)
            addChild(entity)
        }
    }

    /// The '=' token entity, if this row has one.
    public var equalsEntity: TextEntity? {
        guard let index = tokens.firstIndex(where: { $0.kind == .equals }) else { return nil }
        return tokenEntities[index]
    }

    /// Makes each addressable token draggable (payload = its term), or strips
    /// those handles. The game flips this so only the last row can be edited.
    /// The drag uses a proxy that carries a copy of the source's TokenComponent,
    /// so a drop can read the move address off the dragged ghost while the real
    /// token stays put in the row.
    public func setInteractive(_ interactive: Bool) {
        isInteractive = interactive
        for (index, entity) in tokenEntities.enumerated() {
            guard interactive, let address = tokens[index].address, let term = equation.term(at: address) else {
                entity.components.remove(DraggableComponent.self)
                continue
            }
            entity.components[DraggableComponent.self] = DraggableComponent(
                payload: .expression(term),
                makeDragProxy: { [weak self] source in self?.makeProxy(for: source) ?? source }
            )
        }
    }

    private func makeProxy(for source: Entity) -> Entity {
        let component = source.components[TextComponent.self]
        let proxy = TextEntity(glyphs: component?.glyphs ?? [], fontSize: component?.fontSize ?? style.fontSize)
        proxy.name = "token-proxy"
        if let render = source.components[RenderStyleComponent.self] {
            proxy.components[RenderStyleComponent.self] = render
        }
        if let token = source.components[TokenComponent.self] {
            proxy.components[TokenComponent.self] = token
        }
        proxy.shown()
        proxy.position = source.worldBounds.center
        return proxy
    }

    public override func performLayout() {
        guard !tokenEntities.isEmpty else { return }
        var cursor: Real = 0
        var anchor: Real = 0
        for (index, entity) in tokenEntities.enumerated() {
            let box = placementBounds(of: entity)
            cursor += leadingGap(at: index)
            let x = cursor - box.min.x
            entity.position.x = x
            entity.position.y = 0  // shared baseline (glyphs are baseline-relative)
            if tokens[index].kind == .equals { anchor = x + box.center.x }
            cursor += box.size.x
        }
        equalsAnchorX = anchor
    }

    private func leadingGap(at index: Int) -> Real {
        guard index > 0 else { return 0 }
        let token = tokens[index]
        let previous = tokens[index - 1]
        if token.glue { return 0 }
        // Gaps are em-relative (like the glyphs): scale them by the row's font
        // size so a smaller equation keeps the same typographic spacing.
        let em = style.fontSize
        if token.kind == .equals || previous.kind == .equals { return style.equalsGap * em }
        if token.kind == .op || previous.kind == .op { return style.opGap * em }
        return style.interGap * em
    }
}

@MainActor
public final class EquationEntity: Layout {
    public let provider: TokenGlyphProvider
    public var style: EquationStyle
    public private(set) var rows: [EquationRow] = []

    /// The equation the user is currently editing — the last (bottom) row.
    public var current: Equation { rows[rows.count - 1].equation }
    public var editableRow: EquationRow? { rows.last }

    public init(_ equation: Equation, provider: TokenGlyphProvider, style: EquationStyle = EquationStyle()) {
        self.provider = provider
        self.style = style
        super.init()
        name = "equation"
        spacing = style.rowSpacing
        let row = makeRow(equation, showsLHS: true)
        row.setInteractive(true)
    }

    /// Adds a derived row beneath the current one: the previous row freezes
    /// (fades, loses its drag handles), the new row becomes editable. A
    /// continuation row (`showsLHS: false`) renders from its '=' onward.
    @discardableResult
    public func appendRow(_ equation: Equation, showsLHS: Bool = true) -> EquationRow {
        if let previous = rows.last { freeze(previous) }
        let row = makeRow(equation, showsLHS: showsLHS)
        row.setInteractive(true)
        return row
    }

    @discardableResult
    private func makeRow(_ equation: Equation, showsLHS: Bool) -> EquationRow {
        var tokens = equation.buildTokens()
        if !showsLHS, let equalsIndex = tokens.firstIndex(where: { $0.kind == .equals }) {
            tokens = Array(tokens[equalsIndex...])  // continuation: '=' onward
        }
        let row = EquationRow(equation: equation, tokens: tokens, provider: provider, style: style)
        rows.append(row)
        addChild(row)
        if let scene { attach(row, to: scene) }  // addChild only sets the direct child
        return row
    }

    private func freeze(_ row: EquationRow) {
        row.setInteractive(false)
        if let scene {
            let pairs = row.tokenEntities.map {
                AnimationPair(target: $0, blueprint: FadeBlueprint(opacity: style.inactiveRowOpacity))
            }
            scene.interact(Animation(pairs: pairs), for: 0.2.s)
        } else {
            for entity in row.tokenEntities {
                var renderStyle = entity.components[RenderStyleComponent.self] ?? RenderStyleComponent()
                renderStyle.opacity = style.inactiveRowOpacity
                entity.components[RenderStyleComponent.self] = renderStyle
            }
        }
    }

    private func attach(_ entity: Entity, to scene: Scene) {
        entity.scene = scene
        if let group = entity as? Group {
            for child in group.children { attach(child, to: scene) }
        }
    }

    public override func performLayout() {
        guard !rows.isEmpty else { return }
        let boxes = rows.map { placementBounds(of: $0) }
        let totalHeight = boxes.reduce(0) { $0 + $1.size.y } + spacing * Real(Swift.max(rows.count - 1, 0))
        let targetX = rows[0].equalsAnchorX  // every row's '=' lines up here

        var cursorY = totalHeight / 2
        for (row, box) in zip(rows, boxes) {
            row.position.y = cursorY - box.size.y / 2 - box.center.y
            row.position.x = targetX - row.equalsAnchorX
            cursorY -= box.size.y + spacing
        }
    }
}
