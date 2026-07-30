import Foundation

// MARK: - Future: AI inline edit (Cmd+K style)
// Cursor-style: select range → AI rewrites → apply into buffer.
// Wire from Study chat / agent tools; keep Memory DiffPreviewViewController separate.

/// Placeholder for AI-driven inline edits against the code buffer.
protocol CodeEditorAIEditing: AnyObject {
    /// Apply a replacement over `range` (UTF-16) in the editor buffer.
    func applyAIEdit(range: NSRange, replacement: String)
    /// Current plain text + selection for building an edit prompt.
    func aiEditSnapshot() -> (text: String, selectedRange: NSRange)
}

// MARK: - Future: Tab autocomplete / ghost text
// Soft ghost suffix at caret; Tab accepts, Esc dismisses.

protocol CodeEditorCompletionProviding: AnyObject {
    /// Request completions at caret; provider may call back asynchronously.
    func requestCompletions(prefix: String, lineContext: String, completion: @escaping ([String]) -> Void)
}

// MARK: - Future: Inline diff mode (accept/reject hunks)
// Not the Memory `DiffPreviewViewController` sheet — editor-embedded hunks.

protocol CodeEditorDiffPresenting: AnyObject {
    func presentInlineDiff(before: String, after: String)
    func dismissInlineDiff(accept: Bool)
}
