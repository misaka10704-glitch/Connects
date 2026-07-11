# Connects

面向 **老旧 iPad**（尤其是 **iPad Air 1 / iOS 12**）的 AI 聊天客户端。界面参考 ChatGPT 的阅读节奏与侧栏结构，本地配置 API Key，调用 **DeepSeek V4（Flash / Pro）** 与 **Kimi K2.6**。

## 动机

市面上主流 AI 客户端几乎都默认「新系统 + 新设备」：依赖较新的 iOS、只适配大屏或手机，对仍在服役的旧 iPad 支持很差。

我这边还有一台 **iPad Air 1（iOS 12.5.x）**，屏幕与续航仍然适合长时间阅读和推导，却很难找到能稳定跑起来的双模型聊天应用。现成 App 要么装不上，要么界面为手机裁切，要么把 Key 绑死在封闭生态里。

**Connects** 因此做了这些取舍：

1. **兼容优先**：UIKit + iOS 12，不追求 SwiftUI / 最新 API。  
2. **自己带 Key**：DeepSeek / Kimi 分开放进本机钥匙串，不经第三方中转。  
3. **为阅读而排版**：居中阅读列、可调字号、思考过程可折叠，数学与 Markdown 尽量渲染完整。  
4. **会话可带走**：对话自动命名、可分叉、可导出完整 Markdown，方便备份与二次整理。

这不是要替代官方网页版，而是给「旧硬件也想正经用模型」的人一个能装上、能用顺的本地壳。

## 功能概览

- 流式对话（SSE），切换会话时后台生成不中断  
- 多会话：新建 / 搜索 / 归档 / 重命名 / 分叉  
- 模型：DeepSeek V4 Flash、DeepSeek V4 Pro、Kimi K2.6（含图片）  
- 深度思考可开关；Kimi 可切国内 / 海外节点  
- 助手消息：复制、重跑、分叉；完整 Markdown 导出与分享  
- 主题：白天 / 黑夜；聊天字号：小 / 中 / 大  

## 设备与布局

| 项目 | 说明 |
|------|------|
| 目标设备 | iPad（以 iPad Air 1 9.7" 为主） |
| 最低系统 | iOS 12.0 |
| 布局 | 可折叠侧栏 + 居中聊天列（约 720pt 阅读宽） |

仅适配 iPad（`TARGETED_DEVICE_FAMILY = 2`），未做 iPhone 窄屏。

## 打开与运行

```bash
open Connects.xcodeproj
```

1. **Signing & Capabilities** → 选择你的 Team  
2. Destination → 真机 iPad 或 iOS 12+ 模拟器  
3. Run  

真机首次安装后，在「设置 → 通用 → 设备管理」信任开发者证书。

## API 配置

侧边栏 **设置** 中填写 Key：

| 提供商 | 模型 ID | Base URL（示例） |
|--------|---------|------------------|
| DeepSeek | `deepseek-v4-flash` / `deepseek-v4-pro` | `https://api.deepseek.com` |
| Kimi | `kimi-k2.6` | `https://api.moonshot.cn/v1` 或 `https://api.moonshot.ai/v1` |

Key 只存本机 Keychain，不会打进仓库或上传。

## 技术栈

- UIKit（兼容 iOS 12，无 SwiftUI / Combine）  
- `URLSession` SSE；`WKWebView` + KaTeX / marked 渲染正文  
- 会话本地持久化；Markdown 自动落盘与导出  

## 许可与声明

本仓库代码可按需自用与修改。调用各家模型需遵守对应平台条款；费用与配额由你自己的 API Key 承担。

---

若你也在用旧 iPad 做长期阅读 / 推导，欢迎提 Issue 或 PR。
