# Connects

面向 **老旧 iPad**（尤其是 **iPad Air 1 / iOS 12**）的 AI 聊天客户端。界面参考 ChatGPT 的阅读节奏与侧栏结构，本地配置 API Key，调用 **DeepSeek V4（Flash / Pro）**、**Kimi** 等模型。

**当前版本：3.2.0**

介绍页：[https://misaka10704-glitch.github.io/Connects/](https://misaka10704-glitch.github.io/Connects/)

## 3.2 亮点（功能增强 + 稳定版）

- **思考 / 搜索 / 转写**：状态标签展示进度，点击查看 Sheet 全文；去掉内联展开带来的卡顿与整页冻结。深度思考流式时保留三行实时预览，转写与搜索保持折叠。
- **重跑与滚动**：重跑改为增量更新表格行，避免整页闪烁；流式跟底、新对话切换、Study 分栏视口等多项稳定性修补。
- **代码编辑**：修复中文拼音组字被语法高亮打断；手动保存弹出「已保存」提示。
- **细节**：PDF 截图气泡闪现、Ask 选区提交、新对话侧栏刷新等体验修补。

## 3.1 亮点

- **打开原文件（非导入副本）**：Study 用 security-scoped bookmark 直接读写原 PDF / Markdown / 代码；列表移除不影响外部文件。备份含 registry 与 bookmark，**不含**外部原文件本体。
- **Markdown 编辑**：阅读 / 编辑切换，写回原 `.md`（或旧副本）。
- **PDF 划线 + 注释**：选区高亮与文字注释写入原 PDF；发送时优先选区文字与 notes，有文本层时可不截图。
- **代码 Study（先 Verilog）**：等宽编辑器 + 多色语法高亮；AI 上下文为**全文文本**（pin / FILE_REF / delta），无截图。长按「附带文档上下文」可选手动范围。

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

- **Study 模式**：对话「依附于文档」→ 打开 PDF / Markdown / 代码后进入阅读编辑 + AI 分栏；横屏右侧 / 竖屏底部浮动 Chat，默认收起。
- **PDF / Markdown / 代码**：进度记忆；输入栏「附带文档上下文」发送时附带位置或全文（代码）；长按可选范围。
- **文档库**：打开过的文档书签留档；旧版导入副本仍可打开。
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

## 技术栈

- UIKit（兼容 iOS 12，无 SwiftUI / Combine）
- `URLSession` SSE；已完成消息：`NativeMarkdownParser` + `NativeMessageLayouter` + vendored **iosMath 0.9.x**
- 会话本地持久化；Markdown 自动落盘与导出

## 许可与声明

本仓库代码可按需自用与修改。调用各家模型需遵守对应平台条款；费用与配额由你自己的 API Key 承担。

---

若你也在用旧 iPad 做长期阅读 / 推导，欢迎提 Issue 或 PR。
