import AppKit

/// 列表视图的表头：文件名称 / 修改日期 / 大小 / 种类，可点击切换排序（对齐访达）
final class ListHeaderView: NSView {

    /// 点击某一列
    var onPickSort: ((SortMode) -> Void)?

    private var buttons: [SortMode: NSButton] = [:]
    private let separator = NSView()
    /// 三条竖分隔线：分别落在 修改日期 / 大小 / 种类 列的左边界，可以拖着改列宽
    private var dividers: [NSView] = []
    /// 可调的三个宽度约束（跟 ListColumns 同步）
    private var dateWidthConstraint: NSLayoutConstraint!
    private var sizeWidthConstraint: NSLayoutConstraint!
    private var kindWidthConstraint: NSLayoutConstraint!
    private var draggingDivider: Int?
    private var dragStartWidth: CGFloat = 0
    private var dragStartX: CGFloat = 0

    /// 列宽都从 ListColumns 取（表头和行共用一份）
    private var dateWidth: CGFloat { ListColumns.date }
    private var sizeWidth: CGFloat { ListColumns.size }
    private var kindWidth: CGFloat { ListColumns.kind }
    private var leadingInset: CGFloat { ListColumns.leadingInset }
    private var iconArea: CGFloat { ListColumns.iconArea }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        // 表头**不再自带底**：它和表体共用外层那一整块列表底，
        // 这样看起来是"一个表格"，不会表头一条、表体一条地分离。
        wantsLayer = false

        for mode in SortMode.allCases {
            let button = NSButton(title: mode.title, target: self, action: #selector(pick(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11.5, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.alignment = .left
            button.tag = SortMode.allCases.firstIndex(of: mode) ?? 0
            addSubview(button)
            buttons[mode] = button
        }

        // 表头里的列分隔线（访达的表头有细竖线，而且能拖着改列宽）
        dividers = (0..<3).map { _ in
            let v = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.separatorColor.cgColor
            return v
        }

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)
        dividers.forEach { addSubview($0) }

        // 名称列从图标之后开始；其余按固定宽度右对齐排
        let name = buttons[.name]!
        let date = buttons[.dateModified]!
        let size = buttons[.size]!
        let kind = buttons[.kind]!

        NSLayoutConstraint.activate([

            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset + iconArea),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),

            date.centerYAnchor.constraint(equalTo: centerYAnchor),
            size.centerYAnchor.constraint(equalTo: centerYAnchor),

            kind.centerYAnchor.constraint(equalTo: centerYAnchor),
            kind.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            size.trailingAnchor.constraint(equalTo: kind.leadingAnchor, constant: -14),
            date.trailingAnchor.constraint(equalTo: size.leadingAnchor, constant: -14),
            name.trailingAnchor.constraint(lessThanOrEqualTo: date.leadingAnchor, constant: -10),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        dateWidthConstraint = date.widthAnchor.constraint(equalToConstant: dateWidth)
        sizeWidthConstraint = size.widthAnchor.constraint(equalToConstant: sizeWidth)
        kindWidthConstraint = kind.widthAnchor.constraint(equalToConstant: kindWidth)
        NSLayoutConstraint.activate([dateWidthConstraint, sizeWidthConstraint, kindWidthConstraint])

        // 三条竖分隔线，分别落在 日期 / 大小 / 种类 列之前
        NSLayoutConstraint.activate([
            dividers[0].leadingAnchor.constraint(equalTo: date.leadingAnchor, constant: -7),
            dividers[1].leadingAnchor.constraint(equalTo: size.leadingAnchor, constant: -7),
            dividers[2].leadingAnchor.constraint(equalTo: kind.leadingAnchor, constant: -7),
        ] + dividers.map {
            [$0.centerYAnchor.constraint(equalTo: centerYAnchor),
             $0.heightAnchor.constraint(equalToConstant: 14),
             $0.widthAnchor.constraint(equalToConstant: 1)]
        }.flatMap { $0 })
    }

    // MARK: - 拖动分隔线改列宽

    /// 哪条分隔线在鼠标附近（±6pt）。返回 0/1/2 分别对应 修改日期 / 大小 / 种类 的列宽。
    private func dividerIndex(at point: NSPoint) -> Int? {
        for (index, view) in dividers.enumerated() where abs(view.frame.midX - point.x) <= 6 {
            return index
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for view in dividers {
            addCursorRect(NSRect(x: view.frame.midX - 4, y: 0, width: 8, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividerIndex(at: point) else { return super.mouseDown(with: event) }
        draggingDivider = index
        dragStartX = point.x
        dragStartWidth = [dateWidth, sizeWidth, kindWidth][index]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = draggingDivider else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        // 往左拖 = 这一列变宽（这几个列都是右对齐、拖它们的左边界）
        let width = dragStartWidth - (point.x - dragStartX)
        switch index {
        case 0: ListColumns.date = width
        case 1: ListColumns.size = width
        default: ListColumns.kind = width
        }
        applyColumnWidths()
    }

    override func mouseUp(with event: NSEvent) {
        if draggingDivider != nil {
            draggingDivider = nil
            window?.invalidateCursorRects(for: self)
            return
        }
        super.mouseUp(with: event)
    }

    /// 把最新的列宽应用到约束上（行那边由控制器收到通知后各自更新）
    func applyColumnWidths() {
        dateWidthConstraint?.constant = dateWidth
        sizeWidthConstraint?.constant = sizeWidth
        kindWidthConstraint?.constant = kindWidth
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    @objc private func pick(_ sender: NSButton) {
        guard SortMode.allCases.indices.contains(sender.tag) else { return }
        onPickSort?(SortMode.allCases[sender.tag])
    }

    /// 刷新表头文字与排序箭头（访达里当前排序列会变粗并显示箭头）
    func update(sort: SortMode) {
        for (mode, button) in buttons {
            let active = (mode == sort)
            button.font = .systemFont(ofSize: 11, weight: active ? .semibold : .medium)
            button.contentTintColor = active ? .labelColor : .secondaryLabelColor
            button.title = mode.title + (active ? " ↓" : "")
        }
    }
}
