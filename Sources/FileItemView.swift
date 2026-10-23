import AppKit

/// 带悬停高亮的圆角容器，给网格单元做背景
final class HoverBackgroundView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// 一格：大图标 + 文件名（Finder 图标视图的观感）
final class FileItemView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileItemView")

    private let background = HoverBackgroundView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// 穿透显示时在文件名下标注来源子文件夹
    private let folderLabel = NSTextField(labelWithString: "")
    private let badge = NSView()
    /// 标签色点：贴在图标**右上角**（用户要的位置）
    private let tagDots = TagDotsView()
    /// 当前这个格子显示的是哪个文件 —— 缩略图是异步回来的，
    /// 回来时必须核对"格子还是不是它"（复用会换成别的文件，不能张冠李戴）
    private var representedURL: URL?
    private var hovered = false
    /// 由控制器下发：本窗口当前有没有焦点（理由见 FileRowView）
    var windowActive = true {
        didSet { if windowActive != oldValue { refreshBackground() } }
    }

    /// 图标边长跟随"图标大小"滑块
    private var iconSide: CGFloat = ViewSettings.iconSize

    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!

    override func loadView() {
        let container = HoverBackgroundView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.onHoverChanged = { [weak self] inside in
            self?.hovered = inside
            self?.refreshBackground()
        }

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        // Finder 风格：文件名最多两行、居中、不缩小字号
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 12)
        // 换行 + 末行省略（访达图标视图就是这样）：
        // 之前用 byTruncatingMiddle，长名字会出现 "Aseprite.ap" 换行再跟一个 "p"
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = GridMetrics.labelLines
        nameLabel.cell?.truncatesLastVisibleLine = true

        folderLabel.translatesAutoresizingMaskIntoConstraints = false
        folderLabel.alignment = .center
        folderLabel.font = .systemFont(ofSize: 9.5)
        folderLabel.textColor = .tertiaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.maximumNumberOfLines = 1
        folderLabel.isHidden = true
        nameLabel.cell?.wraps = true
        nameLabel.cell?.isScrollable = false
        nameLabel.textColor = .labelColor

        // "里面有新变化"的小蓝点
        badge.translatesAutoresizingMaskIntoConstraints = false
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.isHidden = true

        container.addSubview(iconView)
        container.addSubview(nameLabel)
        container.addSubview(folderLabel)
        container.addSubview(badge)
        container.addSubview(tagDots)
        self.view = container

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: iconSide)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: iconSide)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: GridMetrics.iconTop),
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconWidth, iconHeight,

            // "里面有新变化"的小蓝点：原来在右上角，现在挪到**左上角** ——
            // 右上角让给标签色点（用户要的位置），两个都堆在右上会打架。
            badge.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -3),
            badge.topAnchor.constraint(equalTo: iconView.topAnchor, constant: 1),
            badge.widthAnchor.constraint(equalToConstant: 6),
            badge.heightAnchor.constraint(equalToConstant: 6),

            // 标签色点：右端对齐图标右上角，多个标签往左排
            tagDots.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            tagDots.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -4),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: GridMetrics.labelGap),
            // 名字左右各让开 labelInset —— 横向"名字↔名字"的净空就是靠它和格子间距拼出来的，
            // 想让左右和上下一样松，这两个数得一起看（见 GridMetrics.itemSpacing）
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: GridMetrics.labelInset),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -GridMetrics.labelInset),

            folderLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            folderLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 3),
            folderLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
        ])
    }

    /// 真·缩略图：先用系统图标立刻显示，缩略图生成好再替换。
    /// 文件夹/包跳过 —— 系统给它们的图标本来就对（文件夹的样子、app 的样子）。
    private func applyThumbnail(for item: FileItem, side: CGFloat) {
        guard !item.isDirectory, !item.isPackage else { return }
        let url = item.url
        if let hit = ThumbnailCache.shared.cached(for: url, side: side) {
            iconView.image = hit
            return
        }
        ThumbnailCache.shared.thumbnail(for: url, side: side) { [weak self] image in
            guard let image else { return }
            DispatchQueue.main.async {
                guard let self, self.representedURL == url else { return }   // 已被复用成别的文件
                self.iconView.image = image
            }
        }
    }

    /// 窗口焦点变化时由外部调用，重画选中底色
    func refreshForFocusChange() { refreshBackground() }

    private func refreshBackground() {
        if isSelected {
            // 选中：中性灰底；失焦时进一步变淡
            view.layer?.backgroundColor = windowActive
                ? NSColor.labelColor.withAlphaComponent(0.18).cgColor
                : NSColor.labelColor.withAlphaComponent(0.07).cgColor
        } else if hovered, windowActive {
            // hover 也要看焦点：失焦时鼠标可能还压在图标上（比如程序化切走了前台应用），
            // 这时候留着一块灰底，看起来就像"失焦了还亮着"。实测失焦后画面 0% 变化，
            // 就是这个原因。
            view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        } else {
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override var isSelected: Bool {
        didSet {
            // 选中底色是浅灰，白字会看不见；保持 labelColor
            nameLabel.textColor = .labelColor
            refreshBackground()
        }
    }

    func configure(with item: FileItem, marked: Bool = false, showFolder: Bool = true) {
        // 图标大小可能被滑块改过
        let side = ViewSettings.iconSize
        if abs(side - iconSide) > 0.5 {
            iconSide = side
            iconWidth.constant = side
            iconHeight.constant = side
        }
        iconView.image = item.icon
        representedURL = item.url
        applyThumbnail(for: item, side: side)
        nameLabel.stringValue = item.displayName
        badge.isHidden = !marked
        tagDots.colors = item.tagColors
        let folder = showFolder ? item.relativeFolder : ""
        folderLabel.stringValue = folder.isEmpty ? "" : folder
        folderLabel.textColor = .tertiaryLabelColor
        folderLabel.isHidden = folder.isEmpty
        view.toolTip = item.relativeFolder.isEmpty
            ? "\(item.name)\n\(item.url.path)"
            : "\(item.name)\n来自：\(item.relativeFolder)\n\(item.url.path)"
        refreshBackground()
    }
}
