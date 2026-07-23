# Connects

面向 **老旧 iPad**（尤其是 **iPad Air 1 / iOS 12**）的 AI 聊天客户端。界面参考 ChatGPT 的阅读节奏与侧栏结构，本地配置 API Key，调用 **DeepSeek V4（Flash / Pro）**、**Kimi** 等模型。

**当前版本：3.0.0**

介绍页：[https://misaka10704-glitch.github.io/Connects/](https://misaka10704-glitch.github.io/Connects/)

## 动机

市面上主流 AI 客户端几乎都默认「新系统 + 新设备」：依赖较新的 iOS、只适配大屏或手机，对仍在服役的旧 iPad 支持很差。

我这边还有一台 **iPad Air 1（iOS 12.5.x）**，屏幕与续航仍然适合长时间阅读和推导，却很难找到能稳定跑起来的双模型聊天应用。现成 App 要么装不上，要么界面为手机裁切，要么把 Key 绑死在封闭生态里。

**Connects** 因此做了这些取舍：

1. **兼容优先**：UIKit + iOS 12，不追求 SwiftUI / 最新 API。
2. **自己带 Key**：各提供商 Key 放进本机钥匙串，不经第三方中转。
3. **为阅读而排版**：居中阅读列、可调字号、思考过程可折叠，数学与 Markdown 尽量渲染完整。
4. **会话可带走**：对话自动命名、可分叉、可导出完整 Markdown，方便备份与二次整理。

这不是要替代官方网页版，而是给「旧硬件也想正经用模型」的人一个能装上、能用顺的本地壳。

## 3.0 亮点

- **Study Markdown 实用稳定版**：导入 `.md` 时可多选共享 `assets/` 按文件名匹配；图改为可点预览浮层，不再依赖整页 PDF 固化。
- **目录样式统一**：MD / PDF 侧栏目录对齐 Markdown 简洁标题栏；PDF 书签用文字切换，去掉分段控件。
- **阅读页同步不泄漏**：正文足够时只走 `apiContextPrefix`，不再把页面原文塞进「图片转写 / 页面 OCR」。
- **操作条布局**：复制 / 重跑 / 分叉与版本分页收入同一 Stack，版本号放在三大按钮之后，避免重叠。
- **渲染引擎约定**：聊天气泡以 Native Markdown 为规范引擎；Study WKWebView 仅作过渡壳（见 `.cursor/rules/markdown-render-engine.mdc`）。

## 2.0 亮点

- **Study 模式**：侧栏「学习」入口或对话「依附于文档」→ 选 PDF / Markdown 后进入阅读 + AI 分栏；横屏右侧 / 竖屏底部浮动 Chat，默认收起。
- **PDF / Markdown 阅读**：页码（或滚动进度）与缩放记忆；输入栏可开启「同步阅读页」，发送时附带当前阅读位置文字与截图。
- **文档库**：导入过的 PDF、Markdown 留档，可复用、可备份恢复。
- **统一浮动侧栏**：普通对话与 Study 均全宽主内容，对话列表左缘抽屉呼出，不再挤压聊天列。

## 1.8 亮点

- **会话切换即时化**：侧栏切换先换表再后台预热，去掉 JPEG 快照，尾段同步绘制、历史异步升级，A↔B 来回切换明显更顺。
- **打开更可靠**：恢复上次打开的会话；修复首次切换卡死、二次切换迟滞与冷会话长尾行高探测过慢。
- **问题栏跳转**：竖屏点「问题」菜单跳转时，用户气泡稳定置顶在上下文栏下方，不再随机落在中间或底部。

## 1.7 亮点

- **原生渲染主路径**：已完成助手回复由 Native Markdown + iosMath 绘制，不再依赖整条 WebKit 截图主路线。
- **流式更稳**：固定节奏节流刷新；思考直播展开，结束后默认折叠，减少切入会话时的空白间隔。
- **公式与来源**：行内 / 块级 TeX、窄侧栏缩放、参考链接折叠为可点击来源列表。
- **可选联网检索**：App 代搜注入上下文，文末紧凑标注来源。

## 功能概览

- 流式对话（SSE），切换会话时后台生成不中断
- 多会话：新建 / 搜索 / 归档 / 重命名 / 分叉
- 模型：DeepSeek V4 Flash、DeepSeek V4 Pro、Kimi 等（可扩展可见池）
- 深度思考可开关；Kimi 可切国内 / 海外节点
- 助手消息：复制、重跑、分叉、多版本切换；完整 Markdown 导出与分享
- 主题：白天 / 黑夜；聊天字号：小 / 中 / 大
- 智能体：设置中的独立智能体库创建与编辑，可选 20 种彩色衣服图标；每个对话在输入栏衣服图标选择一个智能体或关闭
- 可选 Memory：输入栏最左侧的大脑图标开启后才读写；侧栏 Memory 页面渲染最近七日日志与整体背景，并可编辑背景 Markdown

## 设备与布局

| 项目 | 说明 |
|------|------|
| 目标设备 | iPad（主）/ iPhone（可安装，UI 仍为 iPad 布局） |
| 最低系统 | iOS 12.0 |
| 布局 | 全宽聊天 / 阅读区 + 左缘浮动侧栏抽屉 |

### 构建路线（源码相同）

| 路线 | Scheme | 设备 | 配置 |
|------|--------|------|------|
| iPad | `Connects-iPad` | iPad（含 Air 1） | Debug / Release |
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

Key 只存本机 Keychain，不会打进仓库或上传。

## 智能体与 Memory

- **智能体**：设置 →「智能体」中创建和编辑。选择智能体只影响该会话发给模型的 system prompt，不会改写聊天气泡或历史消息。
- **Memory**：默认关闭。对话输入栏的「记」按钮开启时，Connects 才会在本机 `Documents/ConnectsMemory/` 中写入当天的提问与有限上下文；关闭后不会读取或写入。
- **保留规则**：最近 7 个自然日保留原始日志。更早日志会自动精炼进背景并保存 revision；用户手动修改背景时显示红绿 diff，点击 Keep 才会写入。
- **管理**：侧栏搜索框下方的 Memory 入口显示统一 Markdown 文档和待确认数量。已确认数据保存在 `Documents/ConnectsMemory/logs/`、`background.md`、`revisions/` 与 `pending/`。

## 技术栈

- UIKit（兼容 iOS 12，无 SwiftUI / Combine）
- `URLSession` SSE；已完成消息：`NativeMarkdownParser` + `NativeMessageLayouter` + vendored **iosMath 0.9.x**
- 会话本地持久化；Markdown 自动落盘与导出

## 许可与声明

本仓库代码可按需自用与修改。调用各家模型需遵守对应平台条款；费用与配额由你自己的 API Key 承担。

---

若你也在用旧 iPad 做长期阅读 / 推导，欢迎提 Issue 或 PR。
