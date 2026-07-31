import Foundation

// MARK: - AI inline edit / Tab / Diff (Study code mode)
// Diff lives in reading mode; Keep enters edit mode. Tab ghost is edit-only.
// Memory DiffPreviewViewController stays separate (orphaned sheet).

protocol CodeEditorAIEditing: AnyObject {
    func applyAIEdit(range: NSRange, replacement: String)
    func aiEditSnapshot() -> (text: String, selectedRange: NSRange)
}

protocol CodeEditorCompletionProviding: AnyObject {
    func requestCompletions(
        fileName: String,
        language: String,
        caretPrefix: String,
        fullText: String,
        lineContext: String,
        linePrefix: String,
        completion: @escaping ([String]) -> Void
    )
}

protocol CodeEditorDiffPresenting: AnyObject {
    @discardableResult
    func presentInlineDiff(before: String, after: String) -> Bool
    func dismissInlineDiff(accept: Bool)
}
