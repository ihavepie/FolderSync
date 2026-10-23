# FolderSync

把任意文件夹变成一个**双向实时同步**的桌面组件：文件夹里变了窗口立刻变，往窗口里拖东西立刻落盘。

补的是「文件夹窗口只有打开那一刻的快照」这个缺口——没有手动刷新，没有过期视图。

## 特性

- **双向实时同步** — FSEvents 递归监听 + 0.15 s 防抖，实测延迟 ~40 ms
- **拖入即落盘** — 默认**复制**，按住 `Option` 拖入才是**移动**
- **不搬文件** — 它只展示和接收拖放，不会把你的东西挪到别处
- **两种视图** — 图标（行优先、纵向滚动、间距随图标大小）／列表（可调列宽）
- **真缩略图** — `QLThumbnailGenerator` 懒加载 + LRU 缓存
- **标签色点** — 读 `xattr`，列表里跟在名字后面，图标视图在右上角
- **快速预览** — 内置浮层，可下钻、`⌫` 回上层、`Esc` 关闭
- **贴桌面** — 可挂到桌面层级，不进 Dock、不占 `⌘Tab`

## 要求

- macOS 13.0 或更高
- Xcode Command Line Tools（`xcode-select --install`），不需要完整 Xcode

## 构建

```bash
git clone https://github.com/ihavepie/FolderSync.git
cd FolderSync
./build.sh
```

产物：`./build/FolderSync.app`，可用 `OUT_DIR` 覆盖输出目录。

首次构建会在 `.signing/` 里生成本地自签证书（约 1 秒，与作者的证书无关）。
`.signing/`、`.modulecache/`、`build/` 都在 `.gitignore` 里。

打包分发：

```bash
./package.sh            # 先编译再打包
./package.sh --no-build # 用现有 app 打包
```

产出 `build/` 下的 `.zip`（解压即用）和 `.pkg`（装到 `/Applications`）。

## 运行

```bash
open ./build/FolderSync.app
```

也可以直接指定要展示的文件夹：

```bash
./build/FolderSync.app/Contents/MacOS/FolderSync --folder ~/Desktop
```

## 权限

首次访问受保护的目录（桌面、文稿、下载、外置盘、网络卷）时系统会询问，同意即可。

窗口里什么都没有、只显示 🔒 时，说明那个目录被拒了——窗口会直接告诉你去哪儿开权限，
也可以从 `⋯ → 重新载入` 重试。

## 已知限制

- 换一台 Mac 首次打开会被 Gatekeeper 拦一次（本地自签证书），右键 → 打开即可
- `.dmg` 在部分机器上造不出来，分发用 zip / pkg
- 点组件窗口会让前台应用的标题栏变灰（键盘输入要求 app 能被激活，这是系统规则）

## 文档

实现细节、踩过的坑、实测数据、架构约束在 [`docs/ENGINEERING.md`](docs/ENGINEERING.md)。
那份是开发记录，不是使用说明。

## 许可证

MIT，见 [LICENSE](LICENSE)。
