# Third-Party Notices

Connects bundles or vendors the following third-party components. Each remains
under its own license; the texts are included next to the component in this
repository. Connects itself is licensed under GPL-3.0 (see `LICENSE`).

| Component | Location in repo | License | Used for |
|-----------|------------------|---------|----------|
| [iosMath](https://github.com/kostub/iosMath) | `Connects/Vendor/iosMath` | MIT (© 2013 MathChat) | Native TeX formula rendering (`NativeFormulaRenderer`) |
| [KaTeX](https://katex.org) | `Connects/Resources/katex` | MIT (© Khan Academy) | Formula snapshots / Study web-shell rendering |
| [marked](https://marked.js.org) | `Connects/Resources/markdown/marked.min.js` | MIT | Markdown → HTML in the transitional Study WKWebView shell |
| [foliate-js](https://github.com/johnfactotum/foliate-js) | `Connects/Resources/Foliate` | MIT (© 2022 John Factotum) | EPUB pagination engine (`FoliateEbookEngine`) |
| [Readium Swift Toolkit](https://github.com/readium/swift-toolkit) | `ThirdParty/readium-swift-toolkit` | BSD 3-Clause (© 2017 Readium) | EPUB navigator / publication parsing |
| XITS Math & Latin Modern Math fonts | `Connects/Resources/mathFonts.bundle` | SIL Open Font License 1.1 | Math typesetting glyphs |

## Notes

- The upstream `ThirdParty/foliate-js/` clone is git-ignored; the app ships a
  pinned copy under `Connects/Resources/Foliate`.
- Model APIs (DeepSeek, Moonshot/Kimi, Qwen, Zhipu, Doubao, MiniMax, StepFun,
  Hunyuan, Yi, SiliconFlow, and user-configured OpenAI-compatible endpoints)
  are third-party services; their terms and pricing apply to your own API keys.
