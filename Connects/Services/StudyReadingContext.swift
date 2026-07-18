import Foundation

protocol StudyReadingContextProviding: AnyObject {
    func captureCurrentStudyPage() -> (label: String, text: String)?
    /// When true, ChatVC should not apply full-screen keyboard lift; the shell resizes the portrait panel.
    var managesPortraitKeyboardLayout: Bool { get }
}

extension StudyReadingContextProviding {
    var managesPortraitKeyboardLayout: Bool { false }
}
