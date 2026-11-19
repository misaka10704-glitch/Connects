# Connects

面向 **iPad** 的开源 AI 聊天与 Study 工作台（**iOS 18+**，GPL-3.0）。界面参考 ChatGPT 的阅读节奏与侧栏结构，本地配置 API Key，调用 **DeepSeek V4（Flash / Pro）**、**Kimi** 等模型，也支持任意 OpenAI 兼容端点（BYOK）。

**当前版本：5.1.0** · **License：GPL-3.0** · 仅源码发行（自签 / sideload，不上架 App Store）

介绍页：[https://misaka10704-glitch.github.io/Connects/](https://misaka10704-glitch.github.io/Connects/)

> **开源说明**：本项目按 GPL-3.0 开源（见 `LICENSE`），第三方组件许可见 `THIRD_PARTY_NOTICES.md`。仓库不含任何 API Key——所有 Key 仅存本机 Keychain。`Connects.xcodeproj` 里保留的 `DEVELOPMENT_TEAM` 是作者个人签名 ID，克隆后请在 Signing 中换成你自己的 Team。

## 5.1 亮点（稳定版）

- **单一侧栏键**：Study 只保留 shell 浮动侧栏；iPhone 同工作区 + / 历史 / ⋯ 回到导航栏右侧并等距排布。
- **图标与输入栏**：顶栏 / 工具行图标尺寸统一；Ask「?」可辨识；深度思考程度仍可长按或在设置中调节（Kimi K3）。
- **项目设置**：可拖拽排序与独立选色页；导航栏不透明，避免列表顶栏变透。
- **可靠性**：Diff 会话持久化；冷启动浮动侧栏位置；空文件保存失败；Files 打开定位到当前文件目录等修补。

## 5.0 亮点（大版本）

- **Study EPUB 阅读**：本地 EPUB 走 Readium 导航器打开；顶栏 A± 调字号、目录跳转、进度记为「第 N / M 页」；主题背景对齐 AI 聊天底色。
- **阅读体验**：左右留白适中、禁双指缩放以免打乱分页；破损 OPF / 无 `spreadLoaded` 的中文书也能出字；打开失败不再误拆已加载的目录。
- **工作区与文档**：文件夹工作区、同目录文件切换与授权体验加固；文档类型登记 EPUB / MOBI（MOBI 暂提示不支持）。
- **聊天与公式**：`$$` 块级公式嵌套修复，以及近期模型下拉、键盘与转写相关修补一并带上。

## 4.0 亮点（大版本）

- **系统底线 iOS 15**：部署目标从 12 升至 15，清理旧系统旁路，换用更稳的现代 API。
- **Study AI Diff**：`CONNECTS_EDIT` 提案进入按块 Keep / Undo 的阅读 Diff；`n/N` 与操作条锚在 hunk 末行，全行红绿底；滚动跟手不漂。
- **编辑链路可靠**：聊天脱敏编辑载荷；未闭合编辑块自动续写；开「AI 编辑」时强制附带文件上下文；失败文案说清「未改文件」，不再空喊「已提出」。
- **聊天与 Study 体验**：长代码块折叠与测高、流式脱敏缓存、Markdown 阅读外层滚动、快捷键与 QA harness 等一并加固。

## 3.2 亮点（功能增强 + 稳定版）

- **思考 / 搜索 / 转写**：状态标签展示进度，点击查看 Sheet 全文；去掉内联展开带来的卡顿与整页冻结。深度思考流式时保留三行实时预览，转写与搜索保持折叠。
- **重跑与滚动**：重跑改为增量更新表格行，避免整页闪烁；流式跟底、新对话切换、Study 分栏视口等多项稳定性修补。
- **代码编辑**：修复中文拼音组字被语法高亮打断；手动保存弹出「已保存」提示。
- **细节**：PDF 截图气泡闪现、Ask 选区提交、新对话侧栏刷新等体验修补。

## 3.1 亮点

- **打开原文件（非导入副本）**：Study 用 security-scoped bookmark 直接读写原 PDF / Markdown / 代码；列表移除不影响外部文件。备份含 registry 与 bookmark，**不含**外部原文件本体。
- **Markdown 编辑**：阅读 / 编辑切换，写回原 `.md`（或旧副本）。
- **PDF 划线 + 注释**：选区高亮与文字注释写入原 PDF；发送时优先选区文字与 notes，有文本层时可不截图。
- **代码 Study（先 Verilog）**：等宽编辑器 + 多色语法高亮；AI 上下文为**全文文本**（pin / FILE_REF / delta），无截图。长按「附带文档上下文」可选手动范围。输入栏「AI 编辑」（深度思考右侧）默认关：开=**授权**模型可提出改文件（非每条必改）；有 `CONNECTS_EDIT` 提案时进**阅读 Diff**（按块接受/拒绝，Cursor 风格浮条）；全部决议后写入并进入编辑。编辑模式 Tab 补全：建议条在光标下方，末尾点「确认」接受（顶栏 Tab 仅开关）。

## 动机

市面上主流 AI 客户端几乎都默认「新系统 + 新设备」：依赖较新的 iOS、只适配大屏或手机，对仍在服役的旧 iPad 支持很差。

早期版本曾瞄准 **iPad Air 1 / iOS 12**；**4.0** 起为 **iOS 15+**；当前底线为 **iOS 18+**，以便 KaTeX / WebKit 公式成图更完整。现成 App 仍常把 Key 绑死在封闭生态里，或界面为手机裁切。

**Connects** 因此做了这些取舍：

1. **UIKit 可读优先**：不追求 SwiftUI 花活；当前要求 iOS 18+。
2. **自己带 Key**：各提供商 Key 放进本机钥匙串，不经第三方中转。
3. **为阅读而排版**：居中阅读列、可调字号、思考过程可折叠，数学与 Markdown 尽量渲染完整。
4. **会话可带走**：对话自动命名、可分叉、可导出完整 Markdown，方便备份与二次整理。

这不是要替代官方网页版，而是给「想正经用模型 + Study 读改文件」的人一个能装上、能用顺的本地壳。

## 3.0 亮点

- **Study Markdown 实用稳定版**：导入 `.md` 时可多选共享 `assets/` 按文件名匹配；图改为可点预览浮层，不再依赖整页 PDF 固化。
- **目录样式统一**：MD / PDF 侧栏目录对齐 Markdown 简洁标题栏；PDF 书签用文字切换，去掉分段控件。
- **阅读页同步不泄漏**：正文足够时只走 `apiContextPrefix`，不再把页面原文塞进「图片转写 / 页面 OCR」。
- **操作条布局**：复制 / 重跑 / 分叉与版本分页收入同一 Stack，版本号放在三大按钮之后，避免重叠。
- **渲染引擎约定**：聊天气泡以 Native Markdown 为规范引擎；Study WKWebView 仅作过渡壳（见 `.cursor/rules/markdown-render-engine.mdc`）。

## 2.0 亮点

- **Study 模式**：对话「依附于文档」→ 打开阅读（PDF / EPUB）或代码/文本（含 Markdown 预览）后进入阅读编辑 + AI 分栏；横屏右侧 / 竖屏底部浮动 Chat，默认收起。
- **PDF / 代码 / Markdown**：进度记忆；输入栏「附带文档上下文」发送时附带位置或全文（代码）；长按可选范围。
- **文档库**：打开过的文档书签留档；旧版导入副本仍可打开。
- **统一浮动侧栏**：普通对话与 Study 均全宽主内容，对话列表左缘抽屉呼出，不再挤压聊天列。

## 1.8 亮点

- **会话切换即时化**：侧栏切换先换表再后台预热，去掉 JPEG 快照，尾段同步绘制、历史异步升级，A↔B 来回切换明显更顺。
- **打开更可靠**：恢复上次打开的会话；修复首次切换卡死、二次切换迟滞与冷会话长尾行高探测过慢。
- **问题栏跳转**：竖屏点「问题」菜单跳转时，用户气泡稳定置顶在上下文栏下方，不再随机落在中间或底部。

## 1.7 亮点

- **原生渲染主路径**：已完成助手回复由 Native Markdown + KaTeX 快照绘制，不再依赖整条 WebKit 截图主路线。
- **流式更稳**：固定节奏节流刷新；思考直播展开，结束后默认折叠，减少切入会话时的空白间隔。
- **公式与来源**：行内 / 块级 TeX、窄侧栏缩放、参考链接折叠为可点击来源列表。
- **可选联网检索**：App 代搜注入上下文，文末紧凑标注来源。

## 功能概览

- 流式对话（SSE），切换会话时后台生成不中断
- 多会话：新建 / 搜索 / 归档 / 重命名 / 分叉
- 模型：DeepSeek、Kimi、Qwen、GLM、豆包、MiniMax、StepFun、混元、Yi、SiliconFlow 等内置目录 + **BYOK 自定义 OpenAI 兼容提供商**
- Study 工作区 Agent：Ask / Plan / Agent 三模式，对整个文件夹 `list_dir` / `read_file` / `grep` / `glob`，`propose_edit` / `create_file` / `delete_file` 全部进逐文件 Diff 审查（Keep / Undo）
- 深度思考可开关；Kimi 可切国内 / 海外节点
- 助手消息：复制、重跑、分叉、多版本切换；完整 Markdown 导出与分享
- 主题：白天 / 黑夜；聊天字号：小 / 中 / 大；界面中 / 英双语

## 设备与布局

| 项目 | 说明 |
|------|------|
| 目标设备 | iPad（主）/ iPhone（可安装，UI 仍为 iPad 布局） |
| 最低系统 | iOS 18.0 |
| 布局 | 全宽聊天 / 阅读区 + 左缘浮动侧栏抽屉 |

### 构建路线（源码相同）

| 路线 | Scheme | 设备 | 配置 |
|------|--------|------|------|
| iPad | `Connects-iPad` | iPad（iOS 18+） | Debug / Release |
| iPhone | `Connects-iPhone` | iPhone（iOS 26 等） | Debug-iPhone / Release-iPhone |

`Connects` scheme 为 **iPad 路线** 的别名。

```bash
./scripts/build-device.sh ipad
./scripts/build-device.sh iphone Release
```

## 打开与运行

```bash
open Connects.xcodeproj
```

1. **Signing & Capabilities** → 选择你的 Team
2. Destination → 选 **Connects-iPad** 或 **Connects-iPhone** scheme，再选真机 / 模拟器
3. Run

真机首次安装后，在「设置 → 通用 → 设备管理」信任开发者证书。

## API 配置

侧边栏 **设置** 中填写 Key：

| 提供商 | 模型 ID（示例） | Base URL（示例） |
|--------|-----------------|------------------|
| DeepSeek | `deepseek-v4-flash` / `deepseek-v4-pro` | `https://api.deepseek.com` |
| Kimi | `kimi-k3`（旗舰）、`kimi-k2.6` 等 | `https://api.moonshot.cn/v1` 或 `https://api.moonshot.ai/v1` |
| 自定义（BYOK） | 任意模型 ID | 任意 OpenAI 兼容端点（base / `/v1` / 完整 `/chat/completions` 均可） |

Key 只存本机 Keychain，不会打进仓库或上传。

## 技术栈

- UIKit（**iOS 18+**，无 SwiftUI / Combine）
- `URLSession` SSE；已完成消息：`NativeMarkdownParser` + `NativeMessageLayouter` → 单张 bitmap 渲染，vendored **iosMath 0.9.x** + KaTeX
- 会话本地持久化；Markdown 自动落盘与导出；EPUB 走 Readium / Foliate

## 许可与声明

- 代码以 **GPL-3.0** 开源，见 `LICENSE`；第三方组件及各自许可见 `THIRD_PARTY_NOTICES.md`。
- 项目仅源码发行（自签或 sideload 安装），不上架 App Store；fork / 再分发请遵守 GPL-3.0（衍生作品同样 GPL-3.0 并保留声明）。
- 调用各家模型需遵守对应平台条款；费用与配额由你自己的 API Key 承担。
- 与 DeepSeek、Moonshot 等模型提供商均无隶属关系。

---

若你也在用旧 iPad 做长期阅读 / 推导，欢迎提 Issue 或 PR。
