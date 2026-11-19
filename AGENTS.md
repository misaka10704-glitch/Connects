# Connects — Agent Notes

iOS chat/study client (UIKit, iOS 18+, bundle `com.misamisa.connects`).

## Build & Verify

```bash
# Simulator
xcodebuild -project Connects.xcodeproj -scheme Connects -configuration Debug \
  -destination 'id=<SIM_UDID>' build

# Physical device
xcodebuild -project Connects.xcodeproj -scheme Connects -configuration Debug \
  -destination 'id=<DEVICE_UDID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <DEVICE_UDID> \
  <DerivedData>/Build/Products/Debug-iphoneos/Connects.app
xcrun devicectl device process launch --device <DEVICE_UDID> com.misamisa.connects
```

- Schemes: `Connects`, `Connects-iPad`, `Connects-iPhone`. Tests: `ConnectsTests` (xcodebuild test).
- Known pre-existing test failures (unrelated to chat work): `ReadiumEbookOpenTests` needs local EPUB fixtures; `testCJKParenBoldBecomesHtmlStrong`.
- DEBUG launch args: `-SettingsPreview`, `-BYOKPreview`, `-ScrollBottom`, `-ScrollMid`, `-AppleLanguages "(zh-Hans)"`.

## Launch screen

App ships the precompiled `Connects/Resources/LaunchScreen.storyboardc` (copied by a build phase); `Connects/LaunchScreen.storyboard` is the source. After editing the source, recompile:

```bash
xcrun ibtool --compile Connects/Resources/LaunchScreen.storyboardc \
  Connects/LaunchScreen.storyboard --minimum-deployment-target 18.0
```

iOS caches launch screens aggressively — verify after uninstall/reinstall or reboot. Logo corners use `layer.cornerRadius` via userDefinedRuntimeAttributes (nib-time KVC, no code).

## Rendering pipeline (canonical)

Chat bubbles (chat + Study sidebar): `NativeMarkdownParser` → `NativeMessageLayouter` → `NativeMessageRenderView` (single `UIImage` bitmap per layout, `NativeMessagePainter` draw commands, manual hit-test for links/code-fence/copy). Math via iosMath `NativeFormulaRenderer` → `UIImage` artifacts; wide formulas get `MathBandScrollView`. Streaming shows raw markdown in `assistantLabel`, swaps to bitmap on finish.

- Rules: new markdown/math/link/table behavior lands in the Native pipeline only — never in `MarkdownHTMLRenderer.studyShellHTML` (Study WKWebView is a transitional shell; see `.cursor/rules/markdown-render-engine.mdc`).
- `MarkdownHTMLRenderer.normalizeForRender` is shared preprocessing — changes benefit both surfaces.
- Cache versions must bump together: `NativeMessageLayouter.layoutCacheVersion`, `ActionIconFactory` cache key.

### Evaluation notes (2026-02)

Bitmap-per-message is a legitimate high-perf route (scroll = texture composite). Real gaps, not tech debt: no text selection, no VoiceOver on message body, 1345-line hand-rolled parser edge cases, raw markdown visible during streaming. If upgraded: prefer `apple/swift-markdown` (cmark-gfm) as parser front-end feeding the same `NativeMessageBlock` AST; selectable text would require UITextView/TextKit hybrid — re-validate scroll perf before committing.

## BYOK (custom OpenAI-compatible providers)

- `AIProvider.custom` + `BYOKProvider` (id/name/baseURL/modelIDs/supportsVision), JSON in `connects_custom_providers` UserDefaults; key in Keychain `custom_apikey_<id>`.
- `AIModelOption.stableID` = `custom|<profileID>|<modelID>`; `catalog` = built-ins + `customModels`.
- Key lookup MUST be model-aware: `SettingsManager.apiKey(for: model)` / `hasAPIKey(for: model)` — provider-level lookup returns "" for `.custom`.
- URL normalization lives in `BYOKProvider.chatCompletionsURL` / `modelsListURL` (accepts base, `/v1`, or full `/chat/completions`).
- Domestic providers keep region endpoints + provider-specific thinking payloads; do not unify them into BYOK.

## Localization

`L("中文", "English")` in `Theme/L10n.swift`; `SettingsManager.appLanguage` (`.system/.zh/.en`), `appLanguageDidChange` notification → settings `rebuildForm()`. New user-facing strings: add both languages at call site.

## Empty-chat lifecycle

`ConversationStore.dropDisposableEmptyConversations()` removes `messages.isEmpty && id != currentConversationID` — runs on load, select, create. Composer text is shared `InputBarView` state, not per-conversation drafts.

## Keys & backup

API keys live in Keychain (`com.misamisa.connects`, `AfterFirstUnlockThisDeviceOnly`) — never in UserDefaults/source. `SettingsManager.sanitizeKey` strips whitespace/BOM/`Bearer ` prefix. Export/backup paths: `ConnectsKeysTransferService`, `ConnectsBackupService` — both include custom provider keys.
