# Connects

面向 **iPad Air 1**（9.7 英寸，768×1024 pt）与 **iOS 12** 的 AI 聊天应用，界面仿 DeepSeek 深色风格，支持自行配置 API Key，调用 **DeepSeek V4 Pro** 与 **Kimi K2.6**。

## 设备与布局

| 项目 | 规格 |
|------|------|
| 目标设备 | iPad Air 1（A7，9.7"） |
| 逻辑分辨率 | 768 × 1024 pt（竖屏）/ 1024 × 768 pt（横屏） |
| 最低系统 | iOS 12.0 |
| 布局 | 左侧固定 280pt 对话列表 + 右侧聊天区（`UISplitViewController`，始终双栏） |

## 功能

- 流式对话（SSE）
- 多会话管理（本地持久化）
- 模型切换：DeepSeek V4 Pro / Kimi K2.6
- API Key 存入钥匙串（DeepSeek、Kimi 分开配置）
- 深色 UI，气泡最大宽度 520pt，适配 9.7 寸阅读宽度

## 打开项目

```bash
open /Users/misaka10704/Documents/Workspace/Connects/Connects.xcodeproj
```

在 Xcode 中：

1. **Signing & Capabilities** → 选择你的 Team
2. **Destination** → iPad Air（或任意 iPad，模拟器选 iOS 12+）
3. Run

> 仅支持 iPad（`TARGETED_DEVICE_FAMILY = 2`），未做 iPhone 窄屏适配。

## API 配置

侧边栏 **设置** 中填写：

| 提供商 | 模型 ID | Base URL |
|--------|---------|----------|
| DeepSeek | `deepseek-v4-pro` | `https://api.deepseek.com` |
| Kimi | `kimi-k2.6` | `https://api.moonshot.ai/v1` |

Key 仅保存在本机 Keychain，不会上传。

## 技术栈

- UIKit（兼容 iOS 12，无 SwiftUI / Combine）
- `URLSession` SSE 流式解析
- `UISplitViewController` 双栏
- `UserDefaults` 会话 + Keychain API Key

## 真机部署（iPad Air 1）

设备最高可升至 **iOS 12.5.7**。用 USB 连接后，在 Xcode 选该设备直接安装；首次需在设备「设置 → 通用 → 设备管理」信任开发者证书。
