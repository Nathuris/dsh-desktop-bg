# desktop-bg

操控**被其他窗口挡住**的 macOS 应用，不把它提到最前。给 DSH 补上两条不走 WindowServer 命中测试的输入通道。

## 为什么需要它

DSH 自带的 computer-use 在 Electron/Chromium 网页内容上会升级到 `delivery_mode:"foreground"`：它的像素级点击最终要交给 WindowServer 派发真实 HID 事件，而 WindowServer 只会把事件给最上面那个窗口。于是"被挡住"就等于"点不到"。

但遮挡只影响这一条通道。macOS 还有两条：

| 通道 | 是否受遮挡影响 | 能做什么 |
|---|---|---|
| Accessibility 元素动作（`AXPress` / `AXFocused`） | 不受影响 | 原生控件、网页里的链接/按钮、文本框聚焦 |
| 进程定向事件（`CGEventPostToPid`） | 不受影响（但 Chromium 会丢弃非 key window 的**鼠标**事件） | 键盘输入、快捷键 |
| 真实 HID 事件 | 影响 | 画布、视频、自绘区域 |

本插件把前两条包成工具。实测：抖音窗口被 DSH 完全盖住时，能往它的搜索框里写字并弹出联想词，且 `frontmost` 全程是 `DSH NEXT`——不抢焦点。

## 工具

| 工具 | 作用 | 遮挡时可用 |
|---|---|---|
| `bg_type` | 聚焦顶层 `AXTextField` 并输入 Unicode 文本（可 `clear` 先清空） | ✅ 已验证 |
| `bg_press` | 按精确 label 触发 `AXPress`，可限定 `role` | ✅ 原生控件与网页按钮/链接 |
| `bg_key` | 往焦点元素发单个按键/组合键 | ✅ 派发成功，效果自负 |
| `bg_click` | 按窗口内**点**坐标向指定 pid 发鼠标点击 | ⚠️ 原生应用可用；Chromium 上无效 |
| `bg_windows` | 列出该进程的 AX 窗口（屏幕坐标，单位为点） | ✅ |
| `bg_probe` | 诊断后台时 AX 树暴露了多少（角色直方图、文本框、权限） | ✅ |

工具返回里的 `verified` 字段是刻意的：

- `ax-value`：读回了控件的 AXValue。证明控件持有这个值，**不**证明网页渲染层已经提交（Chromium 的 AXValue 可能是回声）。
- `dispatch-only`：只证明事件已投递，不证明应用响应了。

`bg_click` 在 Chromium 上会"成功但无效"，因为浏览器进程会把非 key window 的鼠标事件丢掉。这不是 bug，是通道限制；这种情况请用 DSH 的 `delivery_mode:"foreground"`，或者走 CDP。

## 坐标

`bg_click` 收的是**窗口内的点（pt）**，不是截图像素。Retina 上截图像素 ÷ 2；截图被 `max_dimension` 缩放过时，用「截图当前宽度 ÷ 窗口点宽」换算。

## 安装

复制进 DSH profile 的 `plugins/`，加一条依赖和一条 bundle，然后 `pnpm install`：

```sh
PROFILE=~/.dsh/profiles/desktop
mkdir -p "$PROFILE/plugins"
cp -R desktop-bg "$PROFILE/plugins/"

# package.json: dependencies 里加 "desktop-bg": "file:./plugins/desktop-bg"
#               dsh.profile.bundles 里追加 "desktop-bg"
cd "$PROFILE" && pnpm install
```

装完重启 DSH。`cordis.patch.yml` 只做一次 `insert`，不替换任何官方服务，停用即恢复原状。

## 从 GitHub 安装（推荐）

```sh
# profile 的 package.json 里加一条，再 pnpm install
"desktop-bg": "github:Nathuris/dsh-desktop-bg#<commit-sha>"
```

`dsh.profile.bundles` 里同时要有 `desktop-bg`。用 `github:...#sha` 而不是 `file:` 是有原因的：桌面宿主的安装驱动每次启动都会重写 profile manifest，本地路径规格会被丢掉（实测：`file:./plugins/...` 在下次启动时从 dependencies 里消失），而 git 规格会保留。

改完代码后：`git commit` → 把新 sha 写进 dependencies → `pnpm install` → 重启 DSH。

## 依赖与权限

- 需要 DSH 已拿到 **辅助功能（Accessibility）** 权限。插件跑在 DSH 进程里，权限随主进程继承；`bg_probe` 的 `axTrusted` 就是这条检查。
- 不需要屏幕录制权限（本插件不截图）。
- `bin/axhelper` 是 arm64 预编译；架构不匹配时 `lib/helper.js` 会用 `native/axhelper.swift` 现场编译到临时目录（需要 Xcode 命令行工具）。

## 开发

```sh
sh native/build.sh        # 重新编译 helper
node --test test/         # 单元测试，不碰任何用户应用
```

## 已知限制

- Chromium 在窗口不是 key 时会**裁剪 AX 树**（实测同一窗口：前台 218 个节点、后台 602 个但缺少标签页等角色），所以按 label 找元素要以后台视角为准，找不到时先 `bg_probe`。
- 自绘区域（视频播放器、游戏画面）没有可用的 AX 元素，`bg_press` 无从下手，`bg_click` 又被丢弃——这类场景只能前台或用 CDP。
- `CGEventPostToPid` 只在这台机器上验证过 macOS 26.6；更低版本行为可能不同。
