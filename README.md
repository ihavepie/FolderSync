# FolderSync

把任意文件夹变成一个**双向实时同步**的窗口：文件夹里变了窗口立刻变，往窗口里拖东西立刻落盘。

这是为了解决米粒窗口（Milee Grida）做不到的事——它没有文件系统监听，普通文件夹窗口只是打开那一刻的快照。

---

## 1.0 收尾状态

**版本**：`CFBundleShortVersionString = 1.0` / `CFBundleVersion = 1`。
**代码**：26 个 Swift 文件、约 5900 行，`build.sh` 用 `swiftc` + 本地自签证书构建。

### 已验证（有实测证据，不是"应该没问题"）

| 项 | 证据 |
|---|---|
| 双向同步 | FSEvents 递归监听 + 0.15s 防抖，实测延迟 ~37–40ms |
| 图标视图 | 行优先铺满宽度、纵向滚动、间距跟着图标大小（32→20 / 64→28 / 128→36） |
| 装得下就不滚 | 把 clip 推到 (10000,10000)：装得下时被夹回 (0,0)，装不下才给该给的那点 |
| 不画滚动条 | 滚动条视图渲染进位图 = **0 个非透明像素**（系统滚动条是 2845） |
| 标签 | xattr + **元数据即时更新**（`setResourceValue`），色点显示在列表名后 / 图标右上角 |
| 文件夹预览浮层 | 交互自检：往下钻 / ⌫ 回上层 / 钉住回调 / Esc 关闭 全过；贴父窗口、亚克力、面包屑、右键菜单 |
| 真缩略图 | `QLThumbnailGenerator` 懒加载 + LRU；彩色图片目录截图确认显示内容 |
| 排序性能 | 3000 文件 0.224s → **0.040s**（快 5.5 倍），顺序一致 |
| 窗口尺寸记忆 | 改 726×536 → 退出 → 重启后仍是 726×536 |
| 权限 | 缺 5 条 TCC 用途说明 → 已补；读不了时显示 🔒 + 一键去开权限 |
| 自检 | `SELFTEST_OK / CLAMPTEST_OK / SNAPTEST_OK / ROOTTEST_OK / PATHTEST_OK / ARRANGETEST_OK`，typecheck 0 warning |

### 待人工确认（自动化测不出来）

| 项 | 为什么测不了 |
|---|---|
| **空格 = 快速查看** | 依赖"点窗口让本应用成为前台"，而 macOS 14 的协作式激活**不认合成点击**（合成点击能选中条目，但激活请求被系统打回）。真鼠标点一下才算数；不行就走 `⋯ → 快速查看`（菜单是真实手势，那条稳） |
| 拖到访达 / 双击文件夹 / 右键标签后看访达 / 替身·复制·压缩·共享 / 拖走不补位 / 点空白=桌面 | 这台机器上访达窗口打不开、合成拖拽与菜单事件送不进去 |

### 已知取舍与限制

- **去掉 `.nonactivatingPanel`**：键盘（空格/⌫/回车/⌘）要能进来，本应用就必须能被激活，
  所以点组件窗口时前台应用的标题栏会变灰。这是系统规则，绕不过去；
  若哪天嫌它打扰，可以换成"只在按空格那一刻才请求前台"。
- `NSApp.activate(ignoringOtherApps:)` 在 **macOS 14+ 是空操作**（详见 `AppActivation.swift`）。
- `.dmg` 在这台机器上造不出（`hdiutil` 报"目录非空"），分发用 zip / pkg。
- 换一台 Mac 首次打开要被 Gatekeeper 拦一次（本地自签证书），右键 → 打开即可。
- 定稿走 git（`main` 分支 + 版本标签）；`Software/FolderSync/` 下的 zip/pkg 只是分发产物，不是版本记录。
- `build.sh` 里出现的口令 `foldersync` 是**本机临时钥匙串的口令**，证书在本机现生成，不涉及任何真实凭据。

---

## 特性

| 能力 | 实现方式 |
|---|---|
| 文件夹变化 → 窗口实时更新 | FSEvents 递归监听，带 0.15s 防抖，实测延迟 **~37–40ms** |
| 从 Finder 拖入 → 落盘 | 默认**复制**；按住 **Option** 拖入 = **移动** |
| 拖出到 Finder | 自建 `NSDraggingSession`，明确声明 `.copy` 操作掩码 |
| 同名不覆盖 | 自动改名 `report.pdf` → `report 2.pdf` |
| 多窗口 | 每个窗口绑定不同目录，互相独立监听 |
| 文件夹内有变化 | 状态栏提示"N 个文件夹内有新变化"（因为窗口只列一层） |

### 窗口层级（挂桌面）

三种层级，`⌘⇧T` 循环切换，菜单「文件 → 窗口层级」也可选：

| 层级 | 窗口 level 值 | 效果 |
|---|---|---|
| 普通窗口 | `0` | 和普通应用窗口一样 |
| **挂在桌面上** | `-1073741802` | 桌面图标之上、普通窗口之下 → 被别的窗口盖住，像桌面组件 |
| 浮动在最上层 | `3` | 始终可见 |

层级选择会被记住，下次启动沿用。挂桌面模式还会加入所有 Space（切桌面也看得到）。

### 界面：就是一个桌面组件，不是窗口

**窗口里只有内容 + 一个按钮。**

- **左上角**显示文件夹名（标题，13pt 半粗），鼠标悬停可看完整路径
- 顶部中间一条**抓取条**（细横线）→ 在这条里拖动才移动窗口
- 右上角**一个 `⋯` 按钮**（悬停时浮现）→ 所有功能都在它的菜单里
- 右下角一个小状态点：🟢同步中 / 🔵刚有变化 / 🟠读取中
- 亚克力底板（`.hudWindow`）+ 12px 圆角，跟随浅色/深色模式

`⋯` 菜单包含：换文件夹… / 回到上一级 / 在访达中显示 / 窗口层级（钉桌面·浮动·普通，带勾选）/
再开一个窗口… / 关闭这个组件，顶部还会显示当前文件夹名与完整路径。
**对着窗口空白处右键** = 同一个菜单。

### 显示方式 / 整理方式（`⋯` 菜单）

- **显示方式**：图标（默认）/ 列表
  - **图标**：格网排布，底部中间有**图标大小滑块**（32–128pt，连续可调，实时生效）；
    格子之间的间距不用调 —— 跟着图标大小算（见下面「网格间距」一节）
  - **列表**：因为外框是亚克力（比访达的半透更透），列表模式额外加了一层
    `.contentBackground` 内容底板压暗背景，否则文字读不清；再对齐访达的观感——顶部有**可点击排序的表头**
    （名称 / 修改日期 / 大小 / 种类，当前排序列加粗并显示 `↓`），
    每行是 小图标 + 名称 + 修改日期 + 大小 + 种类，隔行浅底色、选中行圆角高亮，
    行宽跟随窗口宽度，表头不随内容滚动。选中用的是**中性灰**而不是强调蓝——
    亚克力底上强调蓝会显得很重、很刺眼
- **整理方式**：按 名称 / 修改日期 / 大小 / 种类 排序（文件夹始终排在前面）
- **自由放置**：打开后可以把每格**拖到任意位置**，位置按「文件夹 + 文件名」记住，
  下次打开还在原处；「重排（清除手动位置）」可一键回到自动网格

图标大小、显示方式、排序、自由放置都存在偏好里，**所有窗口共享**，改一个全都跟着变（和访达一致）。

> 自由放置打开时，拖动格子 = 移动位置（不再拖出文件）；想拖出文件就先关掉自由放置。

### 组件自己的动画

桌面组件"凭空啪一下出现"很出戏，所以窗口的出现和消失都做了收放：

| 动作 | 动画 |
|---|---|
| 出现（启动 / 再开一个窗口） | 淡入 + 从缩小 14pt 展开，0.16s `easeOut` |
| 关闭（`⋯` → 关闭这个组件） | 淡出 + 收到缩小 14pt，0.14s `easeIn`，收完才真正 `close()` |

实测逐帧采样到的过程：

```
出现:  612x432 alpha=0.00 → 625x445 α=0.45 → 633x453 α=0.75 → 639x459 α=0.95 → 640x460 α=1.00
关闭:  640x460 alpha=1.00 → 635x455 α=0.79 → 625x445 α=0.45 → 613x433 α=0.01 → 窗口消失
```

两个细节：动画进行中 `windowDidResize` 直接返回（尺寸在变，跟着重排会看到格子抖），
动画结束后补一次 `refreshLayoutForCurrentSize()`。关掉窗口进程不退出，顶部状态栏图标还在。

### 三处改进：排序性能 / 真缩略图 / 常用文件夹菜单

**① 排序不再重复取属性。** 原来在比较闭包里各调一次 `resourceValues`
（`isDirectory/fileSize/contentModificationDate`）—— 那是系统调用，而比较会被调用
O(n log n) 次。改成先每个文件取一次、再排序。3000 个文件的实测：

```
旧写法 0.224 秒   新写法 0.040 秒   快 5.5 倍
结果顺序一致: true
```

云盘/网络盘（比如 OneDrive 那种路径）上差距更大 —— 那边每次 `resourceValues`
都可能是网络往返。这条只有本地盘能测，所以给的是本地数字。

**② 真缩略图（`ThumbnailCache` + `QuickLookThumbnailing`）。** 以前图标一律是
`NSWorkspace.icon(forFile:)`，那是"文件类型图标"—— 一个塞满照片的文件夹里是
一排一模一样的文档图标。现在用 `QLThumbnailGenerator` 拿**内容缩略图**：

| 设计点 | 为什么 |
|---|---|
| 请求由 `FileItemView.configure` 发起 | NSCollectionView 只配置可见/复用的格子 ⇒ **天然懒加载**，1000 个文件不会一上来生成 1000 张 |
| 先显示系统图标，缩略图好了再替换 | 不为了等缩略图白屏 |
| 缓存键 = 路径 + 修改时间 + 大小 | 文件改了自然失效；LRU 上限 400 张 |
| 并发限 3、回调回主线程时**核对格子还是不是这个文件** | 生成器很重；格子会被复用，不核对就会张冠李戴 |
| 文件夹/包跳过 | 系统给的文件夹/app 图标本来就对 |

实测截图：一个装满彩色 PNG 的目录，组件窗口和预览浮层里都显示出**内容**（橙圆/红方/
黄条纹/蓝圆/渐变/紫方），而不是"一堆一样的文档图标"。

**③ 状态栏「常用文件夹 ▸」。** 当前开着的窗口 + 桌面 / 下载 / 文稿 / 默认目录 +
「选择文件夹…」，不用每次弹面板。

另外预览浮层补了：**路径面包屑**（名字下面一行，缩到"够看就行"）和**右键菜单**
（在新组件窗口中打开 / 在访达中显示 / 拷贝路径 / 钉住此文件夹 —— 都是不改文件的动作，
预览是"只读地看"）。实测：

```
浮层顶栏文字: ["gallery", "8 项", "/tmp/_perf/gallery"]
右键菜单: ["子文件夹", "在新组件窗口中打开", "在访达中显示", "拷贝路径", "钉住此文件夹"]
```

> 构建脚本因此多了 `-framework QuickLookThumbnailing`。

### 文件夹的几种打开方式

| 操作 | 结果 |
|---|---|
| 双击**文件夹** | **在访达里打开**（不替换当前目录） |
| ⌥ + 双击文件夹 | 在旁边开小窗口 |
| **右键文件夹 → 在旁边开小窗口** | 开紧凑小窗口（**只有这个入口**，不做快捷键） |
| 右键文件夹 → 在此窗口中打开（进入下一层） | 想下钻时才用 |

**只有双击会打开**：单击只做选中，不会开小窗、不会开访达。
「在旁边开小窗口」只在**右键文件夹**的菜单里，没有快捷键，避免和双击混淆。

> 打开访达后还要**显式激活一次访达**。本应用是 `.accessory`（后台应用），
> 系统不会因为"一个后台应用请求打开"就把访达切到前面来 —— 实测双击后前台还是原来的应用，
> 访达窗口开在后面，看起来就很生硬。所以 `open` 的回调里补一次
> `NSRunningApplication.activate(options: [])`（用空 option：只激活访达本身，
> 别把它的所有窗口都提上来）。实测：双击前前台是 Edge，双击后变成访达。

### 「打开」一个文件夹：必须显式交给访达

**不能对文件夹用 `NSWorkspace.shared.open(url)`** —— 那会走系统里 `public.folder` 的
"默认打开方式"，而那个默认值**未必是访达**：

```
$ ./handler public.folder
public.folder 默认打开方式 = com.apple.archiveutility      ← 这台机器上居然是它
  候选: [archiveutility, iBooksX, iina, abnerworks.Typora]
```

表现就是"右键 → 打开一个文件夹，结果开出来的是别的东西"（如果那个默认值被设成
FolderSync，就变成"又开出一个 FolderSync"）。

现在统一走 `openItem(at:)`：

| 条目 | 走哪条路 |
|---|---|
| 普通文件夹 | `FileOps.openInFinder` —— 明确指定 `Finder.app`，并显式激活 |
| `.app` 等包 / 普通文件 | `NSWorkspace.shared.open(url)` —— 交给系统默认应用 |

另外把 Info.plist 里那段 `CFBundleDocumentTypes / public.folder` **整个删掉了**：
本应用不再对系统声明"我能打开文件夹"。留着它的代价是
Finder 的「打开方式」里会冒出 FolderSync、还可能被设成文件夹的默认处理器，
而它换来的只是"用 FolderSync 打开文件夹"这一个几乎用不到的功能。
删掉之后实测候选列表里已经没有 `local.foldersync.app` 了。

### 滚不动就是真的滚不动

内容没超出一屏时，**上下一点都不动**：`verticalScrollElasticity = .none`。
不然触控板两指一划，格子会跟着回弹一下，很晃眼。
`.none` 只关"橡皮筋"，真超出一屏时该滚还是能滚 —— 实测：

| 目录 | 内容高 | 视口高 | 可滚 |
|---|---|---|---|
| 3 个文件 | 434 | 434 | **false**（纹丝不动） |
| 40 个文件 | 618 | 434 | true（正常滚） |

### 顶部状态栏那颗图标

`main.swift` 里用的是 `.accessory`：**不进 Dock、不占 ⌘Tab**，存在感只在顶部状态栏：
一个文件夹图标，点开是

```
显示全部组件 / 隐藏全部组件
打开桌面窗口 ⌘D / 打开文件夹… ⌘O
窗口层级 ▸（钉在桌面上 / 浮动在最上层 / 普通窗口）
退出 FolderSync ⌘Q
```

所以"关掉组件"和"退出进程"是两件事：关掉所有窗口进程照样活着，
点状态栏图标就能把组件叫回来，或者从那里真正退出。
（Launchpad 里仍然能找到它、点开就是启动。）

### 主目录：`回到上一级` 的上限

「主目录」= **当前窗口所在的那块盘的根**（`/Volumes/ExampleDisk` 这种）。
退到盘根就停住，不会被带到另一块盘去（比如从外置盘一路退到 Macintosh HD 的 `/`）。
到顶时菜单项**置灰**，快捷键按了也只会响一声。

只限制"往上退"这一个动作 —— `⋯` → 换一个文件夹（⌘O）想去哪都行；
换到别的盘之后，上限就跟着变成那块盘的根。判定逻辑抽成了纯函数
`FolderWindowController.canGoUp(from:)`，用 `--clamptest` 里的 5 个用例做确定性自检。

**首次启动打开哪里**也跟着这个思路走，不再默认 `~/Desktop`：

| app 装在哪 | 默认打开 |
|---|---|
| 外置盘（盘上有 `Applications`） | 那块盘的 `Applications` |
| 外置盘（盘上没有 `Applications`） | 那块盘的根目录 |
| 启动盘 | `~/Desktop`（保持原样） |

原因是 `~/Desktop` 需要「桌面文件夹」授权，而本 app 是 ad-hoc 签名，
**每次重新编译签名都会变、授权都会被 macOS 收回**，每次都要重新点弹窗；
外置盘上的目录不需要任何授权。用 `⌘O` 换过文件夹之后就听你设的，不再用默认值。

### 包（`.app` 这类）当文件看

`.app` 在磁盘上是目录，但对用户来说是一个"文件"。所以：

| | 包（`.app`） | 普通文件夹 |
|---|---|---|
| 显示名字 | **隐藏后缀**（`FolderSync`，不是 `FolderSync.app`） | 保留全名（`My.Folder` 不截断） |
| 双击 | **启动它** | 在访达里打开 |
| 右键 | 打开 / 在访达中显示 / 移到废纸篓 | 多一项「在新窗口中打开」 |
| 列表里的种类 | 应用程序 | 文件夹 |

判定用 `URLResourceKey.isPackageKey`。
把默认目录设成外置盘的 `Applications` 之后这批差异就很明显了 —— 之前双击一个 app
只会跳访达、显示成"FolderSync.app"、种类写着"文件夹"，都不对。

### 标题显示的是"缩过的路径"

**盘就是顶层 `/`** —— 和"回到上一级"的上限是同一条规矩：

| 真实路径 | 标题 |
|---|---|
| `/Volumes/ExampleDisk` | `/` |
| `/Volumes/ExampleDisk/Applications` | `/Applications` |
| `/Volumes/ExampleDisk/Project/FolderSync/Sources` | `/Project/FolderSync/Sources` |
| `/Volumes/ExampleDisk/Project/FolderSync/Sources/Sub` | `/Project/…/Sources/Sub` |
| `~/Desktop` | `~/Desktop` |

规则：家目录缩成 `~`；卷宗根当成 `/`（外置盘上不显示 `/Volumes/名字` 这一段）；
超过三段从中间省略，保留最有辨识度的头尾。
**完整绝对路径仍然在悬停提示和 ⋯ 菜单顶部。**

卷宗根先问系统（`volumeURLKey`），拿不到（比如路径不存在）就按
`/Volumes/<名字>` 这条规则推 —— 纯字符串规则，确定性可测。
用 `--clamptest` 里的 6 个用例自检（`PATHTEST_OK`）。

### 显示的名字

列表和图标里都**隐藏后缀**（`报告.txt` → `报告`），和访达默认行为一致：

- 只对**文件**隐藏，文件夹名照原样显示（`My.Folder` 不会被截断）
- 多重后缀只隐藏最后一个（`archive.tar.gz` → `archive.tar`）
- **隐藏后重名的会恢复成全名**（`重名.txt` / `重名.pdf` 都显示全名），
  这是访达的规则，否则看起来像两个一模一样的文件
- 排序、定位、拖拽、追踪用的仍然是完整文件名，只有显示这一层变了
- 悬停提示里给的是完整名字 + 完整路径，所以后缀永远查得到
- 图标格的宽度取 `max(图标边长 + 44, 88)`：再窄的话长名字会被迫在词中间断开
  （`MagicaVoxel` 这种 11 个字符的名字，70pt 宽正好放不下）
- 格间距收得比较紧（外边距 12 / 格间距 6 / 行间距 8）：外距和内距是**叠加**的，
  两样都给大，看起来就"散"

### 焦点与选中色

**窗口失焦时选中色会变淡**（像访达那样），不会留着一块高亮像是仍然激活。
判定焦点**不能只看一个信号**，因为本窗口是 `.nonactivatingPanel`：
点它不会让本应用变成前台，实测"前台应用"一直显示访达、而 `isKeyWindow` 也仍然是 true。
所以把下面几条都当作失焦的证据，任意一条成立就变淡：

| 信号 | 作用 |
|---|---|
| **全局鼠标监听**（`addGlobalMonitorForEvents`） | **点在别的应用上 = 用户离开了本窗口**。最直接、最可靠的一条 |
| `windowDidResignKey` / `NSWindow.didResignKeyNotification` | 窗口不再是 key |
| `NSWorkspace.didActivateApplicationNotification` | 别的应用被激活 |
| 0.3 秒轮询（`isKeyWindow` + 前台 PID 变化） | 兜底：实测这些通知有时不送达 |

为什么必须有"全局鼠标监听"这一条：最典型的场景是**用户本来就在桌面上**
（前台一直是访达），他点访达自己的窗口时前台**没有换人**、本窗口又因为是
nonactivating panel 而一直是 key —— 这两个信号都什么都告诉不了我们，
只有"鼠标点在别的应用上"这件事是确定的。实测这条链路可靠：
点本窗口 → 变亮；点外面 → 变淡。

反过来"重新有焦点"用**窗口变成 key** 或**用户在本窗口按下鼠标**判定
（本地鼠标监听，和全局监听配成一对）。

还有一个关键点：**格子不能自己读 `view.window?.isKeyWindow` 判断亮暗**——
上面说了它在失焦后仍是 true，自己判就会永远判成"有焦点"，选中色永远不变淡。
焦点状态由控制器下发给格子（`windowActive`），格子只负责照着画。
### 窗口吸附

拖动时（`⋯` → 拖动时吸附，默认开）：

- **拖动过程完全不吸附，跟手移动**；**松手时才吸附**（带 0.12s 收尾动画）
  —— 一开始我在每个拖动事件里都算吸附，鼠标一越过阈值窗口就跳一下，来回穿越就抖，
  所以改成"拖动跟手、松手吸附"
- 靠近屏幕**左/右/底/顶**四边 12pt 内 → 贴边（优先于网格）
- 其余方向对齐到 **20pt 网格**，以可见区原点为基准（所以多个窗口互相对得齐）
- 离格线超过 12pt 就不吸，保持自由位置
- 数学部分抽成了纯函数 `FolderWindowController.snapped(...)`，用 `--clamptest` 里
  的 7 个用例做确定性自检（期望值由独立实现算出，不靠手感）

### 窗口内拖拽 = 换位，不是文件操作

窗口内部的拖拽踩了三层坑，最后是这么做对的。

**① 角标**：macOS 只对 `.copy` 画那个绿色「+」，对 `.move` 不画。
所以落点（不是拖拽源）要根据来源返回不同操作：

```swift
private func isSelfDrag(_ sender: NSDraggingInfo) -> Bool {
    (sender.draggingSource as? FolderCollectionView) === self
}
// draggingEntered / draggingUpdated 里：
if isSelfDrag(sender) { return .move }     // 本窗口内 → 不画角标
updateHint(for: sender)
return FileOps.wantsMove ? .move : .copy   // 外面拖进来 → 照旧
```

**② 源声明的操作集合必须和落点返回的对得上。**
一开始我在拖拽源里按去向分开声明（应用内 `.move`、应用外 `.copy`），
结果**整次拖放被拒绝** —— 表现就是"窗口内拖了没反应" + "拖不出去"。
源老老实实只声明 `.copy`，角标交给落点解决。

**③ 自由摆放模式下不能自己拖着格子走。**
原来的实现是：开了自由摆放，`mouseDragged` 就走"格子跟着鼠标挪"的分支，
**根本不会开始拖拽会话** —— 于是那份窗口里的文件**再也拖不出去**了。
加上"窗口内拖拽会自动切到自由摆放"，就等于"拖一次之后就再也拖不出去"。
现在统一走拖拽会话：窗口内落点 = 换位（落点分支处理），拖到窗口外 = 照常复制/移动。

换位要靠自由摆放布局才留得住位置，所以**第一次窗口内拖拽会顺手把整理方式切到自由摆放**
（`⋯` → 整理方式 里能看到勾选变化）。列表视图是排好序的，拖拽不做换位。

**④ 落在窗口里不再白白复制。** 以前这种情况走 `onDrop` 被当"拖入文件"，
`ingest` 会复制出一份重名文件。现在落点先看来源：

| 拖拽来源 | 落点行为 |
|---|---|
| **本窗口**（`draggingSource === self`） | **换位** |
| 别的应用（访达等） | 落盘（复制 / ⌥ 移动） |

### 组件里的交互规则（一张表）

| 手势 | 行为 |
|---|---|
| 单击图标 | 只选中 |
| 双击图标 | 文件夹 → 访达；文件 → 默认应用 |
| 拖动图标（移动 >4pt 才算） | 起拖拽会话：本窗口内落点 = **换位**；拖到窗口外 = 复制 |
| 右键图标 | 上下文菜单 |
| **空白处拖动** | 框选（⇧ 追加到已有选中） |
| **空白处单击** | 显示桌面 |
| **拖动顶部 26pt 把手条** | 移动窗口（松手吸附到 20pt 网格） |
| Delete / Return | 移到废纸篓 / 打开 |
| `⋯` 按钮 | 菜单 |

这张表在代码里也抄了一份（`FolderCollectionView` 类头部），改行为之前先看那一段。

### 失焦时连 hover 底也要收掉

之前只有"选中色"看焦点，`hover` 底**不看** —— 于是出现这种情况：
鼠标压在某个图标上，然后切到别的应用（鼠标没动），那块灰底就一直留着，
看起来就是"失焦了还亮着"。实测：切走后画面 **0.0% 变化**，灰底纹丝不动。

```swift
} else if hovered, windowActive {     // ← 补上 windowActive
```

现在失焦时 hover 底会跟着收掉，焦点一回来（鼠标还压着的话）又会出现。
实测一整轮：

| 动作 | 画面变化 |
|---|---|
| 点图标选中 | 2.47% |
| 有焦点时悬停另一个图标 | 4.63%（hover 正常出现） |
| 失焦（鼠标仍压着） | 2.32%（hover 收掉 + 选中变淡） |
| 失焦后 vs 最初 | 0.15%（只剩选中那点极淡的底） |

### 点空白处为什么曾经"卡手"

`postShowDesktopHotkey()` 原来是这么写的：

```swift
down.post(tap: .cghidEventTap)
usleep(60_000)          // ← 主线程硬阻塞 60ms
up.post(tap: .cghidEventTap)
```

系统识别快捷键只看 keyDown，那个 `usleep` 纯粹是把**主线程**按住 60ms ——
点完空白处立刻动鼠标、或者再点一下，整个应用还僵着，手感就是"卡手"。
现在 keyUp 走 `DispatchQueue.main.asyncAfter`，不再阻塞；并且把
`orderFrontRegardless()` 挪到发完快捷键之后（延迟敏感的那一步先走）。

### 整理方式：照搬访达

`⋯` → **整理方式** 就是访达图标视图那一套：

| 选项 | 含义 | 内部映射 |
|---|---|---|
| **无** | 位置随便摆 | 自由摆放，顺序不关心 |
| **贴靠网格** | 位置自由，但对齐到网格；拖完自动吸一下 | 自由摆放 + 落点吸附 |
| **按名称 / 按修改日期 / 按大小 / 按种类** | 排好队，不能随便摆 | 关掉自由摆放 + 对应排序 |

同一层菜单里还有：

- **整理** —— 把已经摆好的图标对齐到网格（对应访达的 Clean Up）
- **重排（恢复默认位置）** —— 清掉记录的位置，回到默认排布

列表视图点表头某一列会改排序，此时整理方式会**跟着切到对应的「按xx」**，
菜单勾选和实际排序永远对得上。

老偏好（只有 `freePlacement` + `sortMode` 两个键）会自动推导成新的 `arrangeMode`，不用手动迁移。
映射逻辑抽成了纯数据（`ArrangeMode.isFree` / `.sortMode`），用 `--clamptest` 的 6 个用例自检（`ARRANGETEST_OK`）。

### 列表视图：居中 / 可调列宽 / 拉窗口不闪

三处一起改的：

**① 行内容上下居中。** 之前 icon 和名字分别偏了 `-4` / `-6`，是为了给"来源子文件夹"
那行小字腾位置；列表里早就不显示那行了，偏着就显得没对齐。现在两者都 `centerY`。

**② 列宽可以拖。** 宽度从 `ListHeaderView` 上的 `static let`（只读常量）抽成了
`ListColumns`（存 UserDefaults，带着一条 `.listColumnsChanged` 通知）：

- 表头三条竖分隔线可以拖，鼠标移上去变 `resizeLeftRight` 光标
- 拖完发通知，**表头 + 当前可见的行**一起更新 —— 不用 `reloadData`，所以拖动过程不闪
- 每个窗口一个 observer token，关窗时移除

**③ 拉窗口时列表不再闪。** 原因是 `applyLayout()` 最后无条件 `collectionView.reloadData()`，
而 `windowDidResize` 每帧都会走到它 —— 等于**每帧重建全部行**。现在拆成两条路：

| 时机 | 做什么 |
|---|---|
| 切到列表视图 | `rebuildListLayout()`：建布局 + reloadData（只这一次） |
| 拉窗口 | `resizeListLayoutToFit()`：**只改 `itemSize.width` + `invalidateLayout()`**，不重建、不 reload |

### 图标视图：完全按访达的排法（行优先 + 纵向滚动）

访达图标视图的排法：

| | |
|---|---|
| 排布方向 | **一行铺满窗口宽度，再换下一行**（行优先） |
| 滚动方向 | **纵向**（装不下往下滚） |
| 格子宽度 | **固定**（跟着图标大小走），窗口变宽只是每行多放几格，格子本身不变 |

实测 14 个文件、640x460 的窗口、图标 32pt（一行放 7 个）：

```
文件夹甲  文件夹乙  报告-2026  论文初稿  视频剪辑工程  素材库  项目计划书
音乐素材  Aseprite  config     notes     README        Screenshot  tilemap
```

（图标 32 时 一行 7 个：`stepX = 格子 70 + 间距 20 = 90`，7 格占 610pt，正好铺满 640 的窗口。）

**这里改过一次方向**，值得记下来：上一版写的是"**一列**排满再换右边一列 + **横向**滚动"，
结果窗口一宽图标全挤在左边两三列，右边一大片空白 —— 那是 macOS **桌面图标**的排法
（桌面是从右往左一列列堆），不是访达**窗口**的排法。现在 `IconLayout` 按行算：

```swift
let perRow = max(1, Int(floor((可用宽度 + itemSpacing) / stepX)))
let row = index / perRow          // ← 行优先
let column = index % perRow
origin = (edge + column * stepX, top + row * stepY)
```

两个容易踩的坑：

1. **视口宽度要用 clip view 的**（`enclosingScrollView.contentView.bounds`），不能用
   `collectionView.bounds`：手动位置被拖到右边时内容会变宽、collectionView 跟着变宽，
   拿它算"一行放几格"会越算越多，图标来回跳。
2. 底部那根**图标大小滑块是浮在内容上的**，最后一行不能落在它底下。这个"让位"必须由
   布局自己留（`GridMetrics.bottomReserve`），**不能用 `scrollView.contentInsets`** ——
   见下面「装得下就不给滚」一节，那个 API 会凭空造出一段可滚空间。

**"装得下就不给滚"** —— 图标全都在画面里时，一行都不能滚，滚动条也不该冒出来。
判据是自己算的，不是靠 AppKit 猜：

```swift
let fitHeight = max(itemSize.height + top, viewport.height - bottomReserve)
let height = maxY <= fitHeight ? viewport.height : maxY + bottomReserve
//                                               ↑ 装不下才加这一条
```

**踩过的坑**：一开始是给 `scrollView.contentInsets.bottom = 26` 来避开底部滑块的。
实测（把源码复制到 /tmp 打诊断输出，直接问 clip view）：

```
视口 640x434   内容 640x434   insets=(0,0,26,0)
把 clip 推到 (10000,10000) → 被夹到 (0,26)     ← 明明一样高，却能滚 26pt
```

`contentInsets` **不缩小 clip view**，而是给内容整体多垫一条，于是"图标全都放得下"
的时候滚动条照样出现（用户报的就是这个）。改成布局自己留之后：

| 图标 | 场景 | 视口 | 内容 | 推 (10000,10000) 被夹回 |
|---|---|---|---|---|
| 32 | 桌面 13 项（全放下） | 640×434 | 640×434 | **(0,0)** ← 一点都滚不动 |
| 32 | 应用夹（放不下） | 640×434 | 640×460 | (0,26) ← 只滚需要的那么多 |
| 128 | 桌面 | 640×434 | 640×1004 | (0,570) |

**自动槽位按"条目序号"算，不是"下一个空槽位"** —— 这一点很关键：
找空槽位的话，某一格被拖走（有了手动位置）之后，后面的条目会**往上顶一格补位**，
就是"拖一个别的都乱了"。按序号算就不会：拖走的格子原地留空，其他格子一动不动
（访达正是如此，而且允许两个格子重叠 —— 你可以把一个图标拖到另一个上面）。

不管排布方向怎么改，这条都不受影响：手动位置照样覆盖自动槽位，
"拖走不补位"和"行优先铺满"能同时成立。

顺带删掉了一整套死代码：`groupsEnabled / groupKeys / groupFrames / drawGroupFrames`
（"按来源子文件夹画分组框"那套，早就没人开了）。

### 不画滚动条（`InvisibleScroller`）

滚动条在透明卡片上是**一块"白框"**：系统 `NSScroller` 是连**轨道**一起画的，
而在亚克力上那条浅色轨道特别显眼，`NSScroller` 又没有公开 API 只去掉轨道、留下滑块。
所以组件上**整条都不画** —— `Sources/InvisibleScroller.swift`：

```swift
override func draw(_ dirtyRect: NSRect) {}                       // 不画轨道
override func drawKnob() {}                                      // 不画滑块
override func drawKnobSlot(in: NSRect, highlight: Bool) {}
override class func scrollerWidth(for:scrollerStyle:) -> CGFloat { 0 }   // 不占位
```

两个都是**实测**踩出来的：

| 写法 | 结果 |
|---|---|
| `scrollView.hasVerticalScroller = false` | **不管用**：滚动条视图照样存在、`isHidden == false`、还占右边 16pt；把它渲染进位图数非透明像素 = **2845** |
| 自定义 `NSScroller`（只重写 draw） | 画 0 像素 ✓，但内容一超出、滚动条"该出现"时，滚动视图按**传统滚动条**给它留 15pt，视口 642 → **627**，右边白空一条 |
| 再加 `scrollerWidth = 0` | 视口回到 642 ✓、画 0 像素 ✓ |

验法（都是把视图 `cacheDisplay` 进位图来数像素，别靠肉眼）：

```
视口 642x474 内容 642x546 | 滚动条类=InvisibleScroller 画了 0 像素 | 条目 37 | 还能往下滚 72pt
视口 642x474 内容 642x474 | 滚动条类=InvisibleScroller 画了 0 像素 | 条目 28 | 还能往下滚 0pt
```

**滚动能力一点没少**：滚动条只是个控件，不画它照样能用触控板两指、滚轮、
方向键 / PageUp 滚（上面"还能往下滚 72pt"就是 clip view 自己算出来的可滚范围）。

顺带把 clip view 的白底也早就关掉了（`contentView.drawsBackground = false`）——
那是另一处"拖动时露出白条"的来源。

### 有些文件夹"锁死"：TCC 权限（桌面 / 文稿 / 下载 / 外置盘 / 网络卷）

现象：打开某些目录，窗口里**什么都没有**，看起来像"这个文件夹被锁住了"。

两个原因，都修了：

**① `Info.plist` 里一条权限用途说明都没有。**
`NSDesktopFolderUsageDescription` / `NSDocumentsFolderUsageDescription` /
`NSDownloadsFolderUsageDescription` / `NSRemovableVolumesUsageDescription` /
`NSNetworkVolumesUsageDescription` 五条全部缺失 —— 访问这些受 TCC 保护的目录时
系统给不出正常的授权提示，结果就是被拒。现在都补上了。

**② 错误被吞掉了。**
列目录原来是这么写的：

```swift
let flat = (try? fm.contentsOfDirectory(...)) ?? []     // ← EACCES 也变成"空目录"
```

没权限和"这个目录本来就是空的"完全无法区分，用户只看到一个空窗口。
现在分开了：

```swift
do { flat = try fm.contentsOfDirectory(...) }
catch { denied = Self.isPermissionError(error) }        // NSCocoaErrorDomain 257 / POSIX EACCES
```

没权限时窗口显示 🔒 + 三行说明（去哪儿开权限），状态点变红，重新载入入口在
`⋯ → 重新载入`；状态栏菜单也会**多出两项**（只有真有窗口读不了时才出现）：

```
打开「文件与文件夹」权限设置…      ← 桌面/文稿/下载/外置盘/网络卷 的授权在这里
打开「完全磁盘访问权限」设置…      ← 想直接看 ~/Library、别块盘的任意目录需要这个
```

自检用了真读不了的目录（`chmod 000`）验证：窗口文字、红色状态点、菜单项、
截图都确认过。

### 键盘收不到②：点组件**不会**激活本应用（以及怎么安全地验证）

补一段"怎么确认"的经验，免得下次又白查一小时：

- **`NSWorkspace.frontmostApplication()` 对 `.accessory` app 不可靠**：应用明明已经
  激活了，它还报着上一个普通应用（实测报「访达」），看着像"激活失败"。
- **`NSRunningApplication.isActive` 才是准的**：同一时刻它是 `True`，
  而且此刻按空格 → 预览浮层立刻弹出（385×286 = 620×460 的 62%）。
- **合成点击不算"用户手势"**：macOS 14 的协作式激活会区分来源，我用
  `CGEventPost` 发的点击能选中条目（窗口像素变了 4806）却**不会**激活应用；
  于是自动化测试里"空格没反应"，真机用真鼠标点却是好的。这条只能人工验。
- 想看"这个 app 到底能不能被置前台"，用 AX 直接设 `AXFrontmost = true`：
  返回 0 就说明能（Accessory app 可以，只是不进 Dock）。

顺带两处加固：`WidgetPanel` **去掉了 `.nonactivatingPanel`**（点窗口走 AppKit 标准
激活路径，和 `AppActivation.toFront()` 双保险）；`⋯ → 快速查看` 也改成和空格**同一套
分流**（单个文件夹 → 自研浮层），菜单是真实手势，激活不会被系统打回，所以那条路是稳的。

### 键盘收不到①：macOS 14 起 `activate(ignoringOtherApps:)` 是空操作

现象：**选中文件按空格，空格跑到前台应用那边去了**（实测在浏览器里打了个空格）。

链路是这样的 —— 组件窗口是 `.nonactivatingPanel`（点它**不激活应用**，这是当初为了
"点组件不打扰前台应用"特意设的），而**键盘事件只有在本应用处于激活状态时才会派发给
这个窗口**。所以修法是"点到窗口里就激活自己一次"：

```swift
private func activateAppForKeyboard() {
    AppActivation.toFront()
}
```

**但第一版修复没生效**，原因很隐蔽：`NSApp.activate(ignoringOtherApps: true)` 在
macOS 14+ **被废弃且不做任何事**，编译器只给一句极易被忽略的警告：

```
'activateIgnoringOtherApps' was deprecated in macOS 14.0:
ignoringOtherApps is deprecated in macOS 14 and will have no effect.
```

抽成 `Sources/AppActivation.swift` 里唯一的入口，14+ 用无参 `NSApp.activate()`：

```swift
static func toFront() {
    if NSApp.isActive { return }
    if #available(macOS 14.0, *) { NSApp.activate() }
    else { NSApp.activate(ignoringOtherApps: true) }
}
```

四处调用点全换成它：窗口被点（`FolderCollectionView.mouseDown` → 键盘才有入口）、
预览浮层出现、系统 Quick Look 弹出、`显示桌面` 那条。

**A/B 实测**（同样点一下第一个图标，再按空格；在真 bundle 里跑）：

```
旧构建          按空格后本进程窗口 = [(38,24), (620,460)]              ← 什么都没发生
新构建          按空格后本进程窗口 = [(38,24), (385,286), (620,460)]   ← 文件夹预览浮层弹出 ✓
                  385x286 = 620x460 的 62%，正是预览浮层的尺寸
```

另一个踩到的元坑：调试时我以为"点不到窗口"，其实拿 `NSRunningApplication.isActive`
当判据不可靠（`.accessory` app 上读到的可能是过时值）—— 真正可靠的是"按空格后有没有
多出那个窗口"。


### 文件夹的"Quick Look"：自研预览浮层

系统 `QLPreviewPanel` 对文件夹**只画一个大图标**，不列内容（访达自己也一样），
面板外壳也零定制（没有 API 往里塞自定义视图）。所以文件夹走自研，**文件仍然走系统 QL**
（图片/PDF/Office 那些格式自己渲染不现实）。

空格键的分流在 `FolderWindowController.toggleQuickLookForSelection()`：

```
选中的是单个文件夹 → FolderPreviewController（自研浮层）
其余（文件 / 多选） → QLPreviewPanel（系统）
```

**它和新组件窗口的分工**（设计上的关键，别混）：

| | 预览浮层 | 常驻组件窗口 |
|---|---|---|
| 生命周期 | 空格/Esc/点外面/父窗口关 → 没了 | 常驻，要显式关 |
| 位置 | 不记忆，贴父窗口弹（右侧优先，放不下换左/下，永远在屏内） | 按目录记忆（稳定名 autosave） |
| 依附 | `addChildWindow`：跟着父窗口移动/关闭 | 独立 |
| 拖窗口 | 不能 | 能 |
| 往里拖文件 | **不能**（`acceptsDrops = false`，只读来源目录，免得误操作） | 能 |
| 拖出 / 双击打开 / 往下钻 / ⌫ 回上层 | 能 | 能（⌫ 是移到废纸篓） |
| 常用它 | 点「钉住」→ 变成常驻组件窗口 | — |

「钉住」是"预览 → 固定"那条连续动作的落点：`onPin` → AppDelegate `openWindow(for:)`
→ 位置记忆 + 双向同步 + 可写，浮层自己消失。

自检（不点鼠标，在**真 app bundle 里**跑）：

```
1) 浮层出现 → 目录=子文件夹A 条目数=2 大小=397x286   顶部标签: ["子文件夹A", "2 项"]
2) 双击往下钻 → 条目数=0 顶部=["内层文件夹", "空文件夹"]
3) ⌫ 回上层 → 条目数=2 顶部=["子文件夹A", "2 项"]
4) 点「钉住」→ 回调=子文件夹A 浮层还在=false
6) Esc：开过=true 之后还在=false
```

踩过的坑：

1. **`for v in [backdrop, …] { backdrop.addSubview(v) }`** —— 把 backdrop 自己也塞进数组、
   往自己身上 addSubview，AppKit **直接卡死**（不崩，就是不动了）。
2. **注册了 `FileItemView` 仍报 "must register a nib or a class"**：同一个类、同一个
   identifier，在组件窗口里 `makeItem` 正常，在预览浮层里就是不行。原因没查清；
   预览条目本来就少，改成**直接构造 item**（不复用），问题消失。
3. `⌫` 原来被"选中非空才响应"挡住 —— 预览里没有废纸篓，单独走 `onBack`。
4. 浮层要 `NSApp.activate(ignoringOtherApps: true)` 才收得到空格/Esc/方向键
   （`.accessory` app 不激活时键盘进不来），代价是它会短暂成为前台应用。
5. 查崩溃时踩的元坑：**`swiftc` 的工作目录**不对，`$(cat 某个相对路径列表)` 会去编译
   另一份源码 —— 打点一直不输出，白查了半天。另外"崩溃"有一次其实是 harness 的
   stdout 缓冲没刷、"没输出"被当成了崩溃。

### 标签色点：列表里跟名字后面，图标右上角

`FileItem` 里带上了 `tags`（`kMDItemUserTags` 的名字），两个视图各画一排点：

| 视图 | 位置 |
|---|---|
| 列表 | 紧跟在文件名后面（名字到它这里就不再往右长，免得把日期列顶掉） |
| 图标 | **贴在图标右上角**，右端对齐、多个往左排 |

- 一排**最多三个**（再多就挤了），四标签的实测就是前三个
- 认不出的自定义标签名给灰色，总比不显示强；浅色（黄色）描一圈 0.2 黑边
- 图标视图里原来那个"有变化"的**小蓝点从右上角挪到左上角** —— 右上角让给标签，两个都堆一起会打架

性能上没代价：`tagNamesKey` 和 `isDirectory / fileSize / contentModificationDate`
是**同一次 `resourceValues` 调用**取回来的，不多一次系统调用。

实测截图（一套五个文件：单标签 / 双标签 / 三标签 / 四标签 / 无标签）：
两种视图都正确，四个标签时截到三个、无标签时一个点都不画。


### 快速查看（空格）与标签：两个"点了没反应"

**快速查看**：`keyDown` 里只有 `Delete` / `Return`，**空格（keyCode 49）根本没接** ——
所以只有右键菜单里那一项能用，而且那一项在 `.accessory` app 里还会卡在
"面板成不了 key" 上。现在：

```swift
case 49: onQuickLook?()      // 空格 = 显示/收掉
case 53: hideQuickLook()     // Esc = 关掉

func showQuickLook() {
    NSApp.activate(ignoringOtherApps: true)   // ← 不激活，QLPreviewPanel 出来也按不动
    panel.makeKeyAndOrderFront(nil)
}
```

自检（不用点鼠标）：给 `keyDown` 发一个 `keyCode = 49` 的合成事件 →
`previewURLs = ["one.txt"]`、`QLPreviewPanel.isVisible == true` ✓

**标签**：菜单动作、payload、xattr 全是对的（自检直接 `perform` 那个 action：
文件立刻得到 `["橙色"]`），问题在**写入口**。只写扩展属性时：

```
直接写 xattr        → 立刻 mdls -name kMDItemUserTags = (null)   ← 旧实现
setResourceValue    → 立刻 mdls -name kMDItemUserTags = ("橙色")  ← 现在
```

Spotlight 要过几秒才跟上，而**访达显示标签看的正是这个元数据** ——
所以"点了标签，访达里没反应"。现在走系统正规入口（`NSURL.setResourceValue(_:forKey:.tagNamesKey)`），
元数据当场更新；万一某个文件系统不支持，再退回写 xattr 兜底。

（菜单里的勾选状态本来就按现有标签打，改完标签 `reload()` 一下，
再开菜单就能看到勾 —— 这也是"点到了"的反馈。）

### 整理方式 / 排序方式：访达的模型

访达里这是**两个菜单**，而且互斥：

- **整理方式 ▸**：无 / 贴靠网格 / 按名称 / 按种类 / 按修改日期 / 按大小
- **排序方式 ▸**：名称 / 种类 / 修改日期 / 大小
  —— **整理方式选了"按xx"时，排序方式整项是灰的**（顺序已经由整理方式定死了），
  菜单标题也会变成「排序方式（由整理方式决定）」

「整理」只在 无/贴靠网格 下可用（排好序的时候没什么可整理的）。

### 右键菜单：照访达的结构

```
打开
打开方式 ▸             ← 系统里能打开它的应用（带图标，只对文件显示）
─────────────────
在新组件窗口中打开      ← 仅文件夹（用组件的另一个窗口，不是访达窗口）
在访达中显示
─────────────────
拷贝                   ← 把文件本身放进剪贴板，可以在别处 ⌘V
重新命名…              ← 弹输入框，确认后改名
─────────────────
移到废纸篓
```

右键的那一项若本来就在多选里，整组动作作用于**整个选择**（访达也是这样）。

**逐项对齐访达**（顺序、标题都对齐）：

```
打开
打开方式 ▸                    ← 文件；文件夹这里是「在新组件窗口中打开」
─────────────────
移到废纸篓
─────────────────
拷贝
制作替身
复制
─────────────────
快速查看
─────────────────
显示简介
─────────────────
给…添加标签 ▸                 ← 访达那七种颜色（已有的打勾）+ 清除所有标签
─────────────────
压缩「文件名」                 ← 标题带文件名，和访达一样
─────────────────
共享 ▸                        ← 直接用 NSSharingServicePicker.standardShareMenuItem
─────────────────
在访达中打开 / 在访达中显示     ← 只有组件才有的一项
```

| 项 | 怎么实现的 |
|---|---|
| 拷贝 | `NSPasteboard.writeObjects`，放的是文件本身，可以在别处 ⌘V |
| 制作替身 | `.suitableForBookmarkFile` 的 bookmark data + `URL.writeBookmarkData` → **访达认得的替身**，不是符号链接 |
| 复制 | 复制一份，命名「xx 副本」 |
| 快速查看 | `QLPreviewPanel` + `QLPreviewPanelDataSource`（空格键那套面板） |
| 显示简介 | 自己拼一段信息弹出来（访达的"显示简介"没有公开 API） |
| 给…添加标签 | 写 `com.apple.metadata:_kMDItemUserTags` 扩展属性，内容是 `"名字\n色号"` 的二进制 plist 数组 —— **就是访达自己那套格式**（实测写进去再解出来是 `['红色\n6', '绿色\n2']`） |
| 压缩 | `NSFileCoordinator` 的 `.forUploading` —— 公开 API 里唯一能直接产出 zip 的路子 |
| 共享 | `NSSharingServicePicker(items:).standardShareMenuItem` —— 标题、子菜单、可用服务全由系统决定 |

> 仍然没做：**文件夹操作设置…**（要一套 Folder Actions 绑定）。
> 构建脚本因此多了 `-framework Quartz`（`QLPreviewPanel` 在里面）。

### 网格间距：所有边距只有一个来源，而且跟着图标大小走

之前这些数字散在三处、各写各的：

| 位置 | 值 |
|---|---|
| 流式布局 | inset 12 / 格间距 6 |
| **自由摆放布局** | **inset 18 / 格间距 12** ← 和上面不一致 |
| 格子内部 | iconTop 10 / labelGap 6 |

后果：切换「整理方式」（按名称 ↔ 无/贴靠网格）时图标会整体挪一下，像换了套布局。
现在全部收进 `GridMetrics`：

```swift
static let edge = 12          // 内容与窗口左/右/下
static let top = 10           // 内容与顶部把手条
static let iconTop = 8        // 格子内部
static let labelGap = 4
static let labelBottom = 6
static let labelInset = 2     // 名字距格子左右边
static let iconInset = 8      // 图标距格子左右边
static let labelNeed = 66     // 名字至少这么宽，否则全被截断
```

**格子宽度** = `max(图标 + 图标左右留白, 名字需要的宽度 + 名字左右留白)`，
间距只当**间隙**用 —— 不参与撑格子，否则列数会掉下来反而更散。
宽度是固定的（访达的格子也不随窗口宽度拉伸）：窗口变宽只是能多放几列，
右边留白不变、图标不会跳。

#### 「重排」之后图标贴在一起（横向 ≠ 纵向）

上一版在底部放了**两根滑块**：图标大小 + 网格间距，而网格间距的值直接当横向间隙用：

```swift
static var itemSpacing { ViewSettings.gridSpacing }               // 横向
static var lineSpacing { max(6, ViewSettings.gridSpacing + 2) }   // 纵向
```

问题是两个方向**看得见的净空**根本不是同一个量：

```
纵向：上一格名字底 → 下一格图标顶 = labelBottom 6 + lineSpacing 10 + iconTop 8 = 24pt
横向：两个名字之间             = labelInset 2 + itemSpacing + labelInset 2
```

滑块最小值是 0，于是 `gridSpacing = 0` 时横向净空只剩 **4pt**（实际偏好里就是这个值），
而纵向还有 24pt —— 名字几乎粘在一起，「重排」回到默认位置时最明显。

现在：**底部滑块删掉一根**（只留图标大小，居中），横向间距由纵向净空**反推**：

```swift
static var rowClearance { labelBottom + lineSpacing + iconTop }        // 6 + 10 + 8 = 24
static var itemSpacing  { rowClearance - labelInset * 2 }              // 24 - 4 = 20
static var columnClearance { labelInset * 2 + itemSpacing }            // 20 + 4 = 24 ✓
```

两者恒等：改 `lineSpacing` / `iconTop` / `labelBottom`，横向会自己跟上，不会再各走各的。
实测（640pt 宽窗口，自动）：

| 图标 | 格子 | stepX | stepY | 左右净空 | 上下净空 | 每列行数 | 可放列数 |
|---|---|---|---|---|---|---|---|
| 32 | 70×80 | 90 | 90 | **24** | **24** | 4 | 6 |
| 64 | 80×112 | 100 | 122 | **24** | **24** | 3 | 6 |
| 128 | 144×176 | 164 | 186 | **24** | **24** | 2 | 3 |

想手动调：**现在不用调了**（见下一节）。

#### 间距不再是个设置项：跟着图标大小算

试过两版手动方案都不舒服：底部一根滑块（最小值 0 → 一拉到底名字就贴住），
后来改成状态栏菜单四档（自动/紧凑/宽松/更宽松）—— 还是得自己挑，而且档位之间
跨度大、微调不了。最后一版**把设置项彻底删掉**：

```swift
/// 格子之间看得见的净空：跟图标大小成比例
static func clearance(iconSide: CGFloat) -> CGFloat {
    min(36, max(16, (12 + iconSide * 0.25).rounded()))
}
static func lineSpacing(iconSide:) -> CGFloat { clearance - labelBottom - iconTop }  // 纵向缝
static func itemSpacing(iconSide:)  -> CGFloat { clearance - labelInset * 2 }        // 横向间距
```

道理很简单：间距本来就是为了不糊成一片，**图标小就该紧凑、图标大就该更松**，
没必要让人去想。左右 = 上下这条也还在，而且是构造出来的恒等式：

```
上下净空 = labelBottom + lineSpacing + iconTop   = clearance
左右净空 = labelInset*2 + itemSpacing            = clearance   ✓ 永远相等
```

实测（640pt 宽窗口）：

| 图标 | 格子 | stepX | stepY | 左右净空 | 上下净空 | 每行 |
|---|---|---|---|---|---|---|
| 32 | 70×80 | 86 | 86 | **20** | **20** | 7 |
| 64 | 80×112 | 104 | 126 | **28** | **28** | 6 |
| 128 | 144×176 | 176 | 198 | **36** | **36** | 3 |

拖动底部"图标大小"滑块时，间距实时跟着变（已用 AX 把滑块从 32 设到 64 验证：
每行 7→6、净空 20→28）。注意 `updateItemSize` 里因此多加了一条判断：
**图标从 64 拖到 32 时格子宽度可能一点没变**（宽度有 70 的下限，名字得放得下），
只看宽高变化会漏掉重排，得把 `iconSide` 的变化也算进去。

随之删掉的东西：底部第二根滑块、状态栏菜单「图标间距 ▸」、
`ViewSettings.gridSpacing`/`iconSpacing` 两个偏好键（老值留在 plist 里没人读了）。


### 键盘：⌘ 键和 Delete / Return

审查时发现这两个**之前是死的**：

1. **主菜单的快捷键在 `.accessory` 下不会被派发** —— 这个 app 不进 Dock、不激活，
   主菜单根本不参与按键派发。README 里写的 ⌘D / ⌘O / ⌘W 一直没生效。
   现在装了一个应用级监听（`AppDelegate.installKeyMonitor`）自己接住：
   窗口作用域的（⌘W / ⌘[ / ⌘R / ⌘O / ⌘N）路由给"当前 key 窗口"的控制器，
   应用级的（⌘O / ⌘D）在 AppDelegate 里做。
2. **Delete / Return 依靠第一响应者**，但一直没人调过 `makeFirstResponder` ——
   虽然 `acceptsFirstResponder` 返回 true，集合视图从没被点亮。
   现在在 `mouseDown` 里设一次。

### 窗口内拖拽：后面的图标不该往前挤

自由摆放模式下，位置本来只有"拖过的格子"才记在 `PlacementStore` 里，
其余格子靠布局自动排 —— 于是被拖走的那格一空出来，后面的图标就**往前挤一格**。
访达不会这样（自由摆放就是位置不动、留下一块空）。

现在在拖拽会话开始前，调一次 `freezeFreePlacementPositions()`：
把**所有**格子当前的实际位置钉进布局并落盘。之后谁被拖走都只是留下空位。

### 显示桌面的防抖（为什么曾经"要点两下"）

```swift
if wasClick && !moved && event.clickCount == 1 { showDesktop() }
```

这句本意是防止"双击把桌面切出去又切回来"，但**系统的双击间隔默认 0.5 秒**（还能调到 1 秒以上），
于是"想收回来"的第二下经常落在间隔里被直接丢掉 —— 手感就是"点一下没反应，得再点一下"。

改成按**时间**防抖：200ms 内的连点算一次（照样防闪），之后就每一下都算数。
实测单击一次即生效（画面变化 68%），再点一次原样收回。

### 窗口之间不重叠

新窗口不再用"层叠偏移"（每个右下角挪 26pt）—— 那些做法开两个窗口时，
后开的必定盖住前一个，而桌面组件盖住就没法同时用了。
现在按"窗口大小 + 12pt 间距"在屏幕可见区里扫格子，
取第一个和现有窗口都不相交的位置；真摆满了才退回层叠。

实测开两个窗口：`(0,25) 640x460` 和 `(652,25) 640x460` —— 间隔正好 12pt，不重叠。

### 不能凭空多出一份"重名副本"

踩到的现象：**每次手一抖就多出一个 `xxx 2.txt`**。原因是两件事叠在一起：

1. 在格子上按下鼠标、稍微动一两个像素，就起了拖拽会话（没有位移阈值）；
2. 松手时如果还在窗口里，AppKit 会把这次拖拽当成"拖入自己的目录"，
   于是 `ingest` 老老实实复制了一份，同名不覆盖 → `xxx 2.txt`。

两处都堵上了：

- **拖出加 4pt 位移阈值**：没真的移动就不算拖，正常点击不再变成拖拽。
- **`ingest` 兜底**：来源的父目录就是目标目录时**直接忽略**（静默，不算错误）。
  这样就算拖拽真的发生了、又松手在窗口里，也不可能复制出重名文件。

确定性自检（已经在目录里的文件再 ingest 一次）：

```
$ FolderSync --ingest-test /tmp/_dup /tmp/_dup/报告.txt
copied=0 moved=0 skipped=0          ← 目录里还是只有一个 报告.txt
$ FolderSync --ingest-test /tmp/_dup /tmp/_outside.txt
copied=1 moved=0 skipped=0          ← 对照组：从别处拖入照常复制
```

实机也验了：在格子上拖 2pt 后松手、以及拖 45pt 但松手还在窗口里，
目录内容都保持 `报告.txt` 一个文件不变。

### 拖出去过一次之后就再也拖不动了

`dragSessionActive` 这个标志只被置 `true`，**从来没有复位**：

```swift
dragSessionActive = true          // 开始拖拽时
beginDraggingSession(...)
// …没有任何地方把它改回 false
```

后果就是"拖出去一次之后，这个窗口再也不能拖出文件了"（`mouseDragged` 里那句
`guard !dragSessionActive` 永远不成立）。叠加上"拖进窗口又取消"这种操作，
就变成"先拖一次、取消，然后再也拖不动"。

修法是补上拖拽会话的结束回调，并在 `mouseDown` 里兜一层底：

```swift
override func draggingSession(_ session: NSDraggingSession,
                              endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    dragSessionActive = false
    pendingDragIndexPath = nil; pendingDragURLs = []; pendingDragStart = nil
}
```

实测：连着拖两次，日志里出现两次 `开始拖出`（旧代码第二次不会有）。

### 一个隐蔽的坑：网格索引与数据源必须一致

穿透模式下网格显示的是"子文件夹里的内容 + 顶层条目"，而 `items` 的枚举会跳过目录。
如果右键菜单 / 拖拽 / 选中还去查 `items[indexPath.item]`，
**索引就会错位**，右键会作用到错的条目上。

现在这些地方统一走同一个计算属性 `visibleGridItems`，保证和网格显示的内容一一对应。

### 四个容易踩的实现细节

- **应用级鼠标监听必须校验事件归属**：`NSEvent.addLocalMonitorForEvents` 会收到
  **整个应用**的鼠标事件。每个窗口控制器都挂了拖动监听，若不判断
  `event.window === self.window`，在窗口 B 的把手按下时窗口 A 也会把自己判定成
  "正在拖动" —— 表现是**一拖多个窗口一起动、叠在一起**。
  加了这个判断后，实测拖 A 只有 A 动（对照实验：去掉判断后拖 A 结果 A 没动、C 跳了 579pt）。

- **`NSColor.separatorColor.withAlphaComponent(x)` 会画出黑线**：
  `separatorColor` 本身是"深色 + 极低透明"，覆盖 alpha 等于把它变成 `x` 的黑，
  叠在白底上就是一条明显的灰线（实测 45% 得到 0.55 灰的实线）。
  **语义分隔色直接拿来用，不要改透明度。**
- **无边框窗口 `performClose(nil)` 是空操作**：`.borderless` 没有关闭按钮，
  `performClose` 找不到按钮什么都不做 —— 表现就是"小窗关不掉"。用 `window.close()`。

- **鼠标拖出窗口后框选会"冻住"**：视图只在指针位于自己范围内时才收到 `mouseDragged`。
  解决办法是用 `NSEvent.addLocalMonitorForEvents` 接管这次拖拽，并把
  「命中判定用的矩形」和「绘制用的矩形」分开 —— 前者跟随真实指针，后者裁到可视区，
  混在一起就会错位。
- **按钮用自绘正圆，不要靠 frame 是正方形**：`NSButton` 的固有尺寸会把
  约束成 24×24 的按钮压成 24×20（实测），于是 `cornerRadius = 高度/2` 出来是胶囊。
  现在改成在 `draw(_:)` 里 `NSBezierPath(ovalIn:)` 取较短边居中画圆 ——
  frame 是什么比例都不影响，画出来必是正圆。

### 三种操作不会互相打架

| 你想做的事 | 操作区域 |
|---|---|
| 移动窗口 | 顶部抓取条（26pt）内拖动 |
| **框选文件** | 在网格区域按住拖动 → 画框选中，按住 ⇧ 可叠加。选框对齐访达/桌面观感（系统强调色描边 90% + 同色 14% 填充），用独立浮层绘制，放大缩小都不会有残留。**指针拖出窗口范围也继续跟手**（用应用级事件监听接管手势；命中判定用真实矩形、绘制用裁到可视区的矩形，两者分开才不会错位） |
| **把文件拖出到 Finder** | 直接按住某个文件往外拖（多选时拖走整批） |
| 从 Finder 拖文件进来 | 往窗口里拖 → 默认复制，按住 ⌥ 移动 |

分工是硬性的：抓取条以外的地方**永远不会**移动窗口，所以框选和拖出都不会误触窗口移动。

**内容显示：直接用系统图标，和 Finder 逐像素一致**
（`NSWorkspace.icon(forFile:)`）：文件夹是原生蓝色文件夹、PNG 显示真实缩略图、
PDF/xlsx/md 各自带应用角标、未知扩展名是通用文稿图标，全部与 Finder 相同。

图标 64pt、文件名 12pt 居中最多两行、格间距 12/14，排布也贴近 Finder 图标视图。
子文件夹内有变化时图标右上角显示小蓝点。

### 点这个窗口 = 点桌面

点组件空白处 = 触发系统的「显示桌面」：窗口**滑到一边**、再点一次**自己滑回来**，
和按 Fn+F11 一模一样。

实现就是发一次 `F11 + Fn` 修饰键：

```swift
CGEvent(keyboardEventSource: source, virtualKey: 103, keyDown: true)  // 103 = F11
up.flags = .maskSecondaryFn
```

#### 但它需要「辅助功能」权限

**合成按键会被系统检查权限**。本应用默认没有这个权限，按键会被**直接丢掉** ——
实测：从终端直接起的实例（继承了终端的权限）点了有效（画面变化 93%），
正常双击启动的实例点了**毫无反应**。

所以 `showDesktop()` 先问自己一句：

```swift
if AXIsProcessTrusted(), postShowDesktopHotkey() { return }
toggleHideOtherApplications()      // 兜底
```

- **有权限** → 系统原生那套：窗口滑到一边、再点滑回来，不用我们记任何状态。
- **没权限** → 兜底：`NSApp.activate` + `hideOtherApplications()` 收起来，
  再点一次把应用逐个 `activate()` 放回来。
  手感就是"隐藏窗口 / 显示窗口"，跟系统的滑动动画不是一回事。

状态栏图标 → 「**启用系统「显示桌面」动画…**」会弹出系统授权提示（辅助功能）。
授权之后那一项会自动消失，点空白处就变成原生手感。

> 两个坑：
> 1. **`.accessory`（后台应用）+ 不是当前应用时，`hideOtherApplications()` 是无效的** ——
>    实测调用完别的应用照样露在外面。必须先 `NSApp.activate(ignoringOtherApps: true)`
>    再隐藏，兜底才会真的生效。
> 2. `unhide()` 走 Apple Event，后台应用调用会被直接拒掉；改用 `activate()`
>    （LaunchServices 级别，不需要授权，系统会顺手把应用取消隐藏）。
>
> 另外：macOS 15 上 `CoreDock`（私有框架，老的 `com.apple.showdesktop.awake` 通知）
> 已经不在系统里了，`dlopen` 直接失败，所以那条路根本走不通。

### 多窗口### 多窗口

可以同时开多个窗口，各自绑定不同目录。**窗口位置按目录分别记住**：
同一目录第一次开窗沿用固定位置（重启能恢复），重复开同一目录会各自独立、互不覆盖。

这里的"重启能恢复"曾经是假的，有**两个**原因，缺一个都不行：

**① 名字里用了 `String.hashValue`** —— Swift 的字符串哈希每个进程随机加盐，
同一个目录每次启动算出的名字都不同 ⇒ `setFrameAutosaveName` 等于每次换名字。
实测同一个路径在两个进程里：

```
/Applications → 旧写法: 970620468379110752  /  -48353834577083154   ← 每次都不一样
              → 改后(FNV-1a): FolderSyncWindow-ff74d18a83a25085      ← 稳定
```

**② 设置时机不对** —— `NSWindowController` 在 `super.init(window:)` 里会把它自己的
`windowFrameAutosaveName`（默认空字符串）盖到窗口上。我们原来设在了 `super.init` **之前**，
于是名字被清空。一步一步打出来是这样：

```
① super.init 之前: ok=true  名字=FolderSyncWindow-ba5c1e22bb57fb5a
② super.init 之后:          名字=（空）        ← 被盖掉了
④ super 之后再设一次: ok=true 名字=FolderSyncWindow-ba5c1e22bb57fb5a   ← 稳住
⑤ applyLevelMode 之后:      名字=（没再变）
```

坑在于 `setFrameAutosaveName` **返回 true**，名字当场读回来也对，只有到后面才变空 ——
所以"看起来设置成功了"。现在改成在 `super.init` + `buildUI()` 之后设。

端到端验证（真机）：启动 → AX 把窗口改成 733×511 → 状态栏「退出」→
偏好里出现 `NSWindow Frame FolderSyncWindow-ed2b4f77fff76331 = 0 904 733 511 …` →
再启动，窗口正好是 **733×511** ✓

### 为什么点桌面不会掉到后台

窗口是 `NSPanel` + `.nonactivatingPanel`，并做了这些设置：

| 设置 | 作用 |
|---|---|
| `.nonactivatingPanel` + `canBecomeKey = false` | 点击它不激活本应用，也不让别的应用失活 → 不会"点一下桌面就缩到后台" |
| `level = desktopIconWindow + 1` | 必须**高于访达的桌面图标层**：否则那个窗口会盖在组件上把鼠标事件全吃掉，表现就是"文件选不中、拖不动"（实测踩到过）。同时仍低于普通窗口，所以别的窗口能盖住它 |
| `canBecomeKey = true` | **必须能成为 key**，否则收不到正常鼠标交互。`.nonactivatingPanel` 已保证它不会抢占前台应用 |
| `level = 桌面图标层与普通窗口层之间` | 钉在桌面上；普通窗口能盖住它，切应用它留在原地 |
| `hidesOnDeactivate = false` | 别的应用激活时它不隐藏 |
| `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]` | 切换 Space 跟着走；Mission Control/显示桌面时不动；⌘` 循环不到它 |

默认就是「钉在桌面上」。想临时当普通窗口用，`⋯` → 窗口层级 → 普通窗口。

其他：双击文件夹进入、双击文件用默认程序打开、右键菜单（打开／在此窗口中打开／在访达中显示／移到废纸篓）、Delete 键移到废纸篓、窗口位置和监听目录会记住。

## 构建

需要 Xcode Command Line Tools（`xcode-select --install`），无需完整 Xcode。

```bash
git clone https://github.com/ihavepie/FolderSync.git
cd FolderSync
./build.sh
```

产物：`./build/FolderSync.app`（默认本地自签证书签名，可用 `OUT_DIR` 覆盖）。

> 首次构建会在 `.signing/` 里**自己生成本地自签证书**（约 1 秒），和作者的证书没有任何关系。
> `.signing/`、`.modulecache/`、`build/` 都在 `.gitignore` 里，不进版本库。

### 打包（分发 / 安装）

```bash
./package.sh            # 先编译再打包
./package.sh --no-build # 用现有的 app 打包
```

产物在 `./build/`：

| 文件 | 用途 |
|---|---|
| `FolderSync-<版本>.zip` | 解压即用，最省事（用 `ditto` 打，权限位和扩展属性都保留） |
| `FolderSync-<版本>.pkg` | 双击安装，自动装到 `/Applications` |
| `FolderSync-<版本>.dmg` | 挂载后拖进「应用程序」；**有些机器上 `hdiutil` 不可用，造不出来会自动跳过**，不影响前两个 |

打包前脚本会先 `codesign --verify --deep --strict` 确认签名没坏。

> ad-hoc 签名的两个后果：换一台 Mac 首次打开会被 Gatekeeper 拦（右键 → 打开）；
> 每次重新编译签名都会变，macOS 会把之前授予的「桌面」等权限收回，需要重新点一次「允许」。

## 运行

```bash
open ./build/FolderSync.app
```

首次启动会默认打开你的**桌面**窗口。

- `⌘D` 打开桌面窗口
- `⌘O` 选择任意文件夹（可多次，每次开一个新窗口）
- `⌘W` 关闭窗口（关闭后不再监听该目录）

也可以直接指定目录启动：

```bash
./build/FolderSync.app/Contents/MacOS/FolderSync --folder ~/Desktop --folder ~/Documents
```

### 验证双向同步

```bash
# 观察"文件夹 → 窗口"这条链路（把每次刷新写进日志）
FOLDERSYNC_TRACE=/tmp/trace.log ./build/FolderSync.app/Contents/MacOS/FolderSync --folder ~/Desktop

# 在另一个终端里造点变化
touch ~/Desktop/test.txt

# 看日志
cat /tmp/trace.log
```

```bash
# 确定性自检：框选命中逻辑（走真实视图和真实代码路径）
./build/FolderSync.app/Contents/MacOS/FolderSync --selftest <目录>

# 确定性自检：窗口会不会跑出屏幕
./build/FolderSync.app/Contents/MacOS/FolderSync --clamptest <目录>

# 单独测试落盘逻辑（与拖拽走的是同一份代码）
./build/FolderSync.app/Contents/MacOS/FolderSync --ingest-test <目标目录> <源文件...>          # 复制
./build/FolderSync.app/Contents/MacOS/FolderSync --ingest-test <目标目录> --move <源文件...>   # 移动
```

## 实测结果

在 `/Volumes/ExampleDisk/_foldersync_test` 上验证：

**方向一：文件夹 → 窗口**（4/4 通过，延迟 ~37–40ms）

```
[+0.000s] reload count=3 items=subfolder|alpha.txt|beta.md          ← 启动读取
[+5.713s] reload count=4 items=...|gamma.pdf                        ← 外部新建
[+7.740s] reload count=4 items=...|beta-renamed.md                  ← 外部重命名
[+9.766s] reload count=3 items=...                                  ← 外部删除
[+11.789s] reload count=3 items=...                                 ← 子目录内新增（递归监听）
```

**拖出 → Finder**（已在真实 Finder 上验证）

```
拖拽前 Desktop: 0 个 MARK_145631.txt
悬停时剪贴板: ["MARK_145631.txt"]
已松手
拖拽后 Desktop: 1 个 MARK_145631.txt      ← 真的落到了桌面
应用日志: [FolderSync] 开始拖出: ["MARK_145631.txt"]
```

**方向二：拖入 → 落盘**（4/4 通过）

```
copied=2 moved=0   summary=复制 2 项          ← 默认复制，源文件保留
copied=1 moved=0   结果含 report 2.pdf         ← 同名自动改名，不覆盖
copied=0 moved=1   summary=移动 1 项          ← Option 移动，源文件消失
copied=1 moved=0   结果含 nested/deep.dat     ← 整个目录也能拖入
```

落盘后窗口**无需手动刷新**即显示新内容（同一次 trace 里 `count=8`）。

## 已做过的取舍

- **不显示隐藏文件**（`skipsHiddenFiles`），想改就动 `FolderWindowController.reload()`。
- **不做递归内容展示**：窗口只列当前这一层（和米粒窗口一致）。子目录里的变化只在状态栏提示，不自动展开。
- **复制用 `copyItem`**：跨磁盘可用；大文件复制是同步的，超大文件会短暂卡住界面。
- **ad-hoc 签名**：自己用够了，分发给别人需要正式签名+公证。

## 代码结构

```
Sources/
├── main.swift                    入口；CLI 自检模式；--folder 参数
├── AppDelegate.swift             菜单栏、多窗口管理、监听目录持久化
├── FolderWindowController.swift  单个窗口：watcher ↔ 网格 ↔ 磁盘 的中枢
├── FolderCollectionView.swift    拖入/拖出、双击、右键、键盘
├── FileItemView.swift            一格的渲染（图标 + 名字 + 大小）
├── FileItem.swift                文件模型
├── WidgetPanel.swift             桌面组件式面板（不抢焦点、不掉后台）
├── WindowLevelMode.swift         窗口层级（钉桌面/浮动/普通）
├── DirectoryWatcher.swift        FSEvents 封装（防抖 + 变更路径上报）
├── FileOps.swift                 复制/移动/同名改名/废纸篓
└── ReloadTrace.swift             刷新链路追踪（验证用）
```

## 两个踩过的坑（改代码时注意）

1. **`eventPaths` 不能当 CFArray 读**。带 `kFSEventStreamCreateFlagFileEvents` 时它是 `char **`，用 `unsafeBitCast` 成 `NSArray` 会**段错误**。正确做法是按 `UnsafePointer<UnsafePointer<CChar>?>` 逐项 `String(cString:)`。

2. **`deinit` 里不能调 `stop()`**。`FSEventStreamStop/Invalidate` 要等回调队列排空，而 deinit 可能正好在回调队列上执行 → 死锁。deinit 里只做释放，不等待。

3. **`didDoubleClickItemsAt` 不是 `NSCollectionViewDelegate` 的方法**。它编译能过（只是警告 "nearly matches"），但**永远不会被调用**。双击必须自己重写 `mouseDown`。

4. **绝不能在主线程上建 FSEvents 流**。`FSEventStreamCreate` 内部走 `watch_path`（和 `fseventsd` 通信），**可能长时间甚至永久阻塞**。实测踩到过：应用启动时卡在这一步，主线程僵死，窗口根本不显示，AX 查询也跟着挂起。现在创建/启动全部在专用的 `foldersync.fsevents` 队列上做。

5. **窗口创建/显示期间不能做任何同步文件 I/O**。目录枚举、`resourceValues`、`NSWorkspace.icon` 在网络卷或外接盘卡住时都会长时间不返回——放在启动路径上等于整个应用起不来。现在 `reload()` 全程在后台队列，窗口先用"正在读取…"立刻显示出来。

6. **`watch_path` 万一卡住，功能不能跟着哑掉**。所以有 1.2s 截止时间：到点还没就绪就自动切到 1s 轮询兜底，日志里会打 `FSEvents 未按时就绪，改用轮询`。

7. **拖出到 Finder 必须在拖拽源上声明操作掩码**。这是"拖不出去"的真正原因，值得展开：

   只实现 `collectionView(_:canDragItemsAt:with:)` 和 `pasteboardWriterForItemAt:` 是不够的。
   `draggingSession(_:sourceOperationMaskFor:)` 若返回不含 `.copy` 的掩码，
   **Finder 会认为这次拖拽不允许放下**（光标显示禁止，松手什么都不发生）。
   现在改为自己起 `NSDraggingSession`，并在 `setup()` 里显式
   `setDraggingSourceOperationMask(.copy, forLocal: false)`，
   同时 override `draggingSession(_:sourceOperationMaskFor:)` 返回 `.copy`。
   验证方法：看拖拽中剪贴板有没有 `CorePasteboardFlavorType 'furl'`（= 允许复制的外部拖拽标记）。

8. **多选拖拽要在 `mouseDown` 里快照选中集合**。AppKit 会在 `mouseDown` 处理中把多选压成单选，
   拖起来之后再问"当前选中了什么"就只剩一个了。必须在调用 `super.mouseDown` **之前**把
   `selectionIndexPaths` 存下来。

## 架构上的三个约束（都来自上面 4/5/6）

- 主线程只做 UI；**所有**文件系统 I/O 在后台队列。
- FSEvents 用**独立队列**，与防抖/轮询队列分开，一卡不会全卡。
- 任何"可能永远不返回"的系统调用都配超时 + 降级路径。

诊断这类卡死的命令（很有用）：

```bash
PID=$(pgrep -f "MacOS/FolderSync" | head -1)
sample $PID 3 -file /tmp/sample.txt     # 看主线程 / 各队列卡在哪个系统调用
```

## 许可证

MIT，见 [LICENSE](LICENSE)。
