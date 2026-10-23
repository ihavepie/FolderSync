import AppKit

/// 列表视图的一行，列宽与 ListHeaderView 对齐：名称 / 修改日期 / 大小 / 种类
final class FileRowView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileRowView")

    private let background = HoverBackgroundView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    /// 穿透显示时在名称后附上来源子文件夹
    private let folderLabel = NSTextField(labelWithString: "")
    private let separator = NSView()
    private let badge = NSView()
    /// 标签色点：跟在文件名后面（访达列表也是这样）
    private let tagDots = TagDotsView()
    /// 这一行现在显示的是哪个文件（异步缩略图回来时要核对）
    private var representedURL: URL?
    /// 三个可调列宽约束（跟 ListColumns 同步）
    private var kindWidthConstraint: NSLayoutConstraint!
    private var sizeWidthConstraint: NSLayoutConstraint!
    private var dateWidthConstraint: NSLayoutConstraint!
    private var hovered = false
    private var striped = false
    /// 由控制器下发：本窗口当前有没有焦点。
    /// 千万不要在这里读 `view.window?.isKeyWindow` ——
    /// 本窗口是 nonactivating panel，失焦之后 isKeyWindow 依然是 true（实测），
    /// 所以自己判断永远判成"有焦点"，选中色就不会变淡。
    var windowActive = true {
        didSet { if windowActive != oldValue { refreshBackground() } }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    override func loadView() {
        let container = HoverBackgroundView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.masksToBounds = true
        container.onHoverChanged = { [weak self] inside in
            self?.hovered = inside
            self?.refreshBackground()
        }

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        for label in [nameLabel, dateLabel, sizeLabel, kindLabel, folderLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12.5)
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = .labelColor
        }
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.alignment = .left
        sizeLabel.font = .systemFont(ofSize: 12)
        kindLabel.font = .systemFont(ofSize: 12)
        kindLabel.alignment = .left
        dateLabel.textColor = .secondaryLabelColor
        sizeLabel.textColor = .secondaryLabelColor
        kindLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        // 行分隔线：不画了。
        // 每一行都来一条会在白底上形成"一条条浅线"，视觉上很碎；
        // 改用隔行底色区分行（更接近访达的观感）。
        separator.isHidden = true

        badge.translatesAutoresizingMaskIntoConstraints = false
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 2.5
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.isHidden = true

        folderLabel.font = .systemFont(ofSize: 10.5)
        folderLabel.textColor = .tertiaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingHead   // 保留结尾，路径尾部更有信息量

        for v in [iconView, nameLabel, dateLabel, sizeLabel, kindLabel, folderLabel, separator, badge, tagDots] {
            container.addSubview(v)
        }
        self.view = container

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                              constant: ListColumns.leadingInset + 2),
            // 行内容上下居中：之前 icon/name 各偏了 -4 / -6，是为了给"来源子文件夹"
            // 那行小字腾位置；现在列表里不再显示那行，偏着就显得没对齐。
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),

            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                               constant: ListColumns.leadingInset + ListColumns.iconArea),
            nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            // 标签色点：紧跟在名字后面；名字到它这里就不再往右长，
            // 免得长文件名把色点顶到日期列里去。
            tagDots.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            tagDots.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: tagDots.leadingAnchor, constant: -6),
            tagDots.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),

            kindLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            kindLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            sizeLabel.trailingAnchor.constraint(equalTo: kindLabel.leadingAnchor, constant: -14),
            sizeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            dateLabel.trailingAnchor.constraint(equalTo: sizeLabel.leadingAnchor, constant: -14),
            dateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            // 来源子文件夹放在名称**下方**（列表里默认不显示）
            folderLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            folderLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            folderLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -10),

            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                           constant: ListColumns.leadingInset + 2),
            badge.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -1),
            badge.widthAnchor.constraint(equalToConstant: 5),
            badge.heightAnchor.constraint(equalToConstant: 5),

            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        kindWidthConstraint = kindLabel.widthAnchor.constraint(equalToConstant: ListColumns.kind)
        sizeWidthConstraint = sizeLabel.widthAnchor.constraint(equalToConstant: ListColumns.size)
        dateWidthConstraint = dateLabel.widthAnchor.constraint(equalToConstant: ListColumns.date)
        NSLayoutConstraint.activate([kindWidthConstraint, sizeWidthConstraint, dateWidthConstraint])
    }

    /// 列宽变了（拖表头分隔线）→ 更新自己的约束
    func applyColumnWidths() {
        kindWidthConstraint?.constant = ListColumns.kind
        sizeWidthConstraint?.constant = ListColumns.size
        dateWidthConstraint?.constant = ListColumns.date
    }

    override var isSelected: Bool {
        didSet { refreshBackground() }
    }

    /// 窗口焦点变化时由外部调用，重画选中底色
    func refreshForFocusChange() { refreshBackground() }

    private func refreshBackground() {
        // 窗口失焦时，选中要"退下去"（访达也是这个行为），
        // 否则点了别处还留着一块高亮，看着像仍然激活。
        if isSelected {
            view.layer?.backgroundColor = windowActive
                ? NSColor.labelColor.withAlphaComponent(0.18).cgColor
                : NSColor.labelColor.withAlphaComponent(0.07).cgColor
        } else if hovered, windowActive {
            // 同 FileItemView：失焦时不留 hover 底
            view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
        } else if striped {
            // 隔行底色：访达用的是"另一个底色"而不是叠加透明，
            // 这里用系统控件底色，和表头材质能区分开
            view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.28).cgColor
        } else {
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func configure(with item: FileItem, marked: Bool, striped: Bool, showFolder: Bool = false) {
        self.striped = striped
        applyColumnWidths()
        iconView.image = item.icon
        representedURL = item.url
        if !item.isDirectory, !item.isPackage {
            let url = item.url
            if let hit = ThumbnailCache.shared.cached(for: url, side: 36) {
                iconView.image = hit
            } else {
                ThumbnailCache.shared.thumbnail(for: url, side: 36) { [weak self] image in
                    guard let image else { return }
                    DispatchQueue.main.async {
                        guard let self, self.representedURL == url else { return }
                        self.iconView.image = image
                    }
                }
            }
        }
        nameLabel.stringValue = item.displayName
        dateLabel.stringValue = item.modified.map { Self.dateFormatter.string(from: $0) } ?? "--"
        sizeLabel.stringValue = item.isDirectory ? "--" : item.sizeText
        kindLabel.stringValue = item.kindText
        let folder = showFolder && !item.relativeFolder.isEmpty ? item.relativeFolder : ""
        folderLabel.stringValue = folder.isEmpty ? "" : "位置：\(folder)"
        folderLabel.isHidden = folder.isEmpty
        badge.isHidden = !marked
        tagDots.colors = item.tagColors
        view.toolTip = item.tags.isEmpty
            ? "\(item.name)\n\(item.url.path)"
            : "\(item.name)\n\(item.url.path)\n标签：\(item.tags.joined(separator: "、"))"
        refreshBackground()
    }
}
