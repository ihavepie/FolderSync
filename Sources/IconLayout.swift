import AppKit

/// 图标视图布局 —— 按**访达**的方式来：
///
/// 1. **一行一行排**：从左往右铺满窗口宽度，再换下一行（行优先）
/// 2. 列宽/行高**固定**（跟着图标大小走），不随窗口宽度拉伸：
///    窗口变宽只是**每行多放几格**，格子本身大小不变 —— 访达也是这样
/// 3. 装不下就**纵向滚动**（访达图标视图是纵向滚，不是横向滚）
/// 4. 有手动位置的格子用它的位置，其余按序号自动排；
///    自动排布**只跟条目序号有关**，所以拖走一个不会让后面的往前顶（不补位）
///
/// 早期版本这里是"一列排满再换右边一列 + 横向滚动"（那是 macOS 桌面图标
/// 从右往左一列列堆的那种排法），结果窗口一宽，图标全挤在左边几列，
/// 右边一大片空白 —— 访达窗口不是这样的。
final class IconLayout: NSCollectionViewLayout {

    /// 手动指定的位置（自由摆放 / 贴靠网格）；排好序的整理方式下为空
    var positions: [IndexPath: NSPoint] = [:]
    /// 格子宽高（由 `GridMetrics.itemSize(iconSide:)` 算出来）
    var itemSize = NSSize(width: 70, height: 80)
    /// 当前图标大小：格子之间的间距跟着它走（见 `GridMetrics.clearance`）
    var iconSide: CGFloat = ViewSettings.iconSize

    private var cache: [NSCollectionViewLayoutAttributes] = []
    private var contentSize = NSSize.zero

    private var stepX: CGFloat { itemSize.width + GridMetrics.itemSpacing(iconSide: iconSide) }
    private var stepY: CGFloat { itemSize.height + GridMetrics.lineSpacing(iconSide: iconSide) }

    override func prepare() {
        super.prepare()
        cache.removeAll()
        guard let collectionView else { return }
        let count = collectionView.numberOfItems(inSection: 0)

        // 视口尺寸要用**可见区域**的，不能用 collectionView.bounds：
        // 手动位置伸到右边/下边时内容会变大、collectionView 跟着变大，
        // 拿它算"一行放几格"会越算越多，图标就会来回跳。
        let clip = collectionView.enclosingScrollView?.contentView.bounds.size
        let viewport = clip ?? collectionView.bounds.size

        // 一行放几格（由窗口**宽度**决定，和高度无关）
        let usableWidth = max(viewport.width - GridMetrics.edge * 2, itemSize.width)
        let spacing = GridMetrics.itemSpacing(iconSide: iconSide)
        let perRow = max(1, Int(floor((usableWidth + spacing) / stepX)))


        var maxX: CGFloat = 0
        var maxY: CGFloat = 0
        for index in 0..<count {
            let indexPath = IndexPath(item: index, section: 0)
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.size = itemSize

            // 自动位置**只跟条目序号有关**：第 n 个就放第 n 个槽位。
            //
            // 关键区别：不是"找下一个空槽位"。找空槽位的话，某一格被拖走（有了手动位置）之后，
            // 后面的条目会**往上顶一格补位** —— 就是"拖一个别的都乱了"。
            // 按序号算就不会：拖走的格子原地留空，其他格子一动不动（访达就是这样，
            // 而且允许两个格子重叠 —— 你可以把一个图标拖到另一个上面）。
            let origin: NSPoint
            if let manual = positions[indexPath] {
                origin = manual
            } else {
                let row = index / perRow
                let column = index % perRow
                origin = NSPoint(x: GridMetrics.edge + CGFloat(column) * stepX,
                                 y: GridMetrics.top + CGFloat(row) * stepY)
            }
            attributes.frame = NSRect(origin: NSPoint(x: max(0, origin.x), y: max(0, origin.y)),
                                      size: itemSize)
            cache.append(attributes)
            maxX = max(maxX, attributes.frame.maxX)
            maxY = max(maxY, attributes.frame.maxY)
        }

        // 内容要不要滚，看的是"**装得下就一点都别给滚**"：
        //
        //   装得下 → 内容高 = 视口高（可滚范围 0，滚动条根本不出现）
        //   装不下 → 内容高 = 最后一格底 + bottomReserve
        //            （多留这一段，滚到底时最后一行正好落在底部滑块上方）
        //
        // 关键：**别用 scrollView.contentInsets 给滑块让位**。实测那玩意儿不缩小 clip，
        // 而是给内容加出一条可滚空间（内容 434 = 视口 434，却还能滚 26pt），
        // 于是图标全都放得下的时候滚动条也会冒出来。位置由这里自己留。
        let fitHeight = max(itemSize.height + GridMetrics.top,
                            viewport.height - GridMetrics.bottomReserve)
        let width = maxX <= viewport.width ? viewport.width : maxX + GridMetrics.edge
        let height = maxY <= fitHeight ? viewport.height : maxY + GridMetrics.bottomReserve
        contentSize = NSSize(width: width, height: height)
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        cache.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        cache.first { $0.indexPath == indexPath }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}
