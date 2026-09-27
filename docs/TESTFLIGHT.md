# Connects → TestFlight（内部 Beta）

## 标识

| 项 | 值 |
|---|---|
| Bundle ID | `com.misamisa.connects` |
| Version / Build | `5.1.0` / `510` |
| Team | `C8XVZJLC2D` |
| Archive Scheme | `Connects-iPhone`（`TARGETED_DEVICE_FAMILY=1,2`） |
| Archive Configuration | `Release-iPhone` |
| 最低系统 | iOS 18.0 |

若 App Store Connect 上同 build 已占用，只 bump `CFBundleVersion`（如 `511`）。

## 工程已具备

- Asset Catalog `AppIcon`（含 iPhone + iPad + 1024 marketing）已接入 `ASSETCATALOG_COMPILER_APPICON_NAME`
- `ITSAppUsesNonExemptEncryption = false`
- `PrivacyInfo.xcprivacy`（UserDefaults `CA92.1`、File Timestamp `C617.1`）

## 你需要在账号侧完成

1. 确认 Apple Developer Program 付费会员有效（Team `C8XVZJLC2D`）。
2. Xcode → Settings → Accounts → 选中 Team → Manage Certificates → **+ Apple Distribution**。  
   本机目前只有 Apple Development 时，无法签 TestFlight 包。
3. [App Store Connect](https://appstoreconnect.apple.com) → My Apps → **New App**（若尚无）：
   - Name: Connects  
   - Bundle ID: `com.misamisa.connects`  
   - 主语言、SKU 自定  
4. App 信息最低填齐；加密问卷选「仅使用豁免加密 / 标准 HTTPS」。  
   隐私政策可用介绍页：https://misaka10704-glitch.github.io/Connects/
5. Users and Access：把测试 Apple ID 加为 **Internal Tester**（同 Team，最多约 100）。

## 上传步骤

### 推荐：Xcode Organizer

1. 打开 `Connects.xcodeproj`
2. Scheme 选 **Connects-iPhone**，Any iOS Device
3. Product → **Archive**
4. Organizer → **Distribute App** → App Store Connect → Upload（Automatic signing）
5. ASC → TestFlight → 等处理完成 → Internal Group → 分发
6. 设备用同一 Apple ID 打开 TestFlight 安装

### CLI 预检 Archive

```bash
./Scripts/archive-testflight.sh
# 产物默认：/tmp/Connects-TestFlight.xcarchive
```

成功后仍建议用 Organizer 上传（或 `xcodebuild -exportArchive` + Transporter）。

## 已知风险（不挡内部 TF）

- `NSAllowsArbitraryLoads = true`：内部 Beta 通常可过；对外 Beta / 正式审可能被追问，上架前改为按域名 ATS 例外。
- Mac Catalyst entitlements 中关沙盒：纯 iOS Archive 一般无影响，勿为 TF 改掉。

## 排查

| 现象 | 处理 |
|---|---|
| No signing certificate / Distribution | 见上文创建 Apple Distribution |
| Missing App Icon / 1024 | 确认 `Assets.xcassets` 在 target Resources，且 `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` |
| Invalid Bundle / version already used | bump `CFBundleVersion` |
| Encryption compliance | Info.plist 已有 `ITSAppUsesNonExemptEncryption=false`；ASC 问卷与之对齐 |
