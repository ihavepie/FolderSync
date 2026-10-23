import AppKit

/// 网格的所有间距集中在这里。
///
/// 之前这些数字散在三处、各写各的：
///   流式布局  inset 12 / 间距 6
///   自由摆放  inset 18 / 间距 12   ← 和上面不一致
///   格子内部  iconTop 10 / labelGap 6
/// 后果是切换「整理方式」时（按名称 ↔ 无/贴靠网格）图标会整体挪一下，
/// 看起来像"换了套布局"。现在只有一个来源。
enum GridMetrics {

    /// 内容与窗口左/右/下边缘的距离
    static let edge: CGFloat = 12
    /// 内容与顶部把手条的距离（比左右略小，视觉上和标题那行更齐）
    static let top: CGFloat = 10

    /// 名字至少要有这么宽，否则全被截断
    static let labelNeed: CGFloat = 66

    // MARK: - 格子内部

    /// 格子内部：图标上边距
    static let iconTop: CGFloat = 8
    /// 格子内部：图标与名字之间
    static let labelGap: CGFloat = 4
    /// 格子内部：名字下方留白
    static let labelBottom: CGFloat = 6
    /// 名字距格子左右边的距离（名字居中，两边各让开这么多）
    static let labelInset: CGFloat = 2
    /// 图标距格子左右边的距离（图标居中，两边各让开这么多）
    static let iconInset: CGFloat = 8
    /// 名字最多几行（决定格子高度）
    static let labelLines: Int = 2

    // MARK: - 格子之间

    /// 底部浮着「图标大小」滑块，内容要给它留出一条。
    ///
    /// **不能用 `scrollView.contentInsets` 留** —— 实测那样做不会缩小 clip，
    /// 而是让内容整体多出一条可滚动的空间（内容 434 = 视口 434，却还能滚 26pt），
    /// 于是"图标全都放得下"的时候滚动条也会冒出来。所以由布局自己留。
    static let bottomReserve: CGFloat = 26

    /// 格子之间**看得见的净空**：跟着图标大小走（小图标紧凑、大图标宽松）。
    ///
    /// 32pt → 20，64pt → 28，96pt 以上封顶 36；再小也不低于 16。
    /// 之前这是个手动档位（外加"自动 = 恒等于 24"），现在是算出来的：
    /// 间距本来就是为了不糊成一片，图标小就该紧凑、图标大就该更松。
    static func clearance(iconSide: CGFloat) -> CGFloat {
        min(36, max(16, (12 + iconSide * 0.25).rounded()))
    }

    /// 行与行之间（格子上下的缝）：净空里减掉格子内上下那两段留白
    static func lineSpacing(iconSide: CGFloat) -> CGFloat {
        max(0, clearance(iconSide: iconSide) - labelBottom - iconTop)
    }

    /// 格子横向间距：净空里减掉名字左右两边让开的 inset
    ///
    /// 这样"两个名字之间"和"上一行名字底 → 下一行图标顶"量出来是同一个数，
    /// 左右和上下永远一样松（改一个另一个自动跟上）。
    static func itemSpacing(iconSide: CGFloat) -> CGFloat {
        max(0, clearance(iconSide: iconSide) - labelInset * 2)
    }

    /// 纵向相邻两格之间看得见的净空：上一格名字底 → 下一格图标顶
    static func rowClearance(iconSide: CGFloat) -> CGFloat {
        labelBottom + lineSpacing(iconSide: iconSide) + iconTop
    }

    /// 横向相邻两格之间看得见的净空：两个名字之间
    static func columnClearance(iconSide: CGFloat) -> CGFloat {
        labelInset * 2 + itemSpacing(iconSide: iconSide)
    }


    /// 格子尺寸。
    /// 宽度按"图标 / 名字谁更需要"起算，是**固定尺寸**（访达的格子也不随窗口宽度拉伸）。
    static func itemSize(iconSide: CGFloat) -> NSSize {
        // 访达的格子是**固定尺寸**：宽度 = max(图标需要的, 名字需要的)，
        // 不随窗口宽度拉伸 —— 窗口宽了只是能多放几列，格子本身不变。
        // 早期版本是"用可用宽度均分"，于是 32pt 的图标被塞进 97pt 的格子，
        // 图标之间净空 57pt，看着很散；而且一改窗口大小图标就会跳。
        let width = max(iconSide + iconInset * 2, labelNeed + labelInset * 2)

        let lineHeight = ceil(NSFont.systemFont(ofSize: 12).boundingRectForFont.height)
        let height = iconTop + iconSide + labelGap
            + lineHeight * CGFloat(labelLines) + labelBottom
        return NSSize(width: max(64, width), height: ceil(height))
    }
}
