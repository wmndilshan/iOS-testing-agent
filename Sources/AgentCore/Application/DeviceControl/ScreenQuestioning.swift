import Foundation

/// Answers a question about what a screenshot shows, in words. It is how an agent that works from text can look at the pixels when the element
/// list is not enough (an icon with no label, a chart, a web page). The answer is text: the agents' models never receive an image.
public protocol ScreenQuestioning: Sendable {
    /// `screenshot` is a JPEG or PNG of the current screen. Throws when the vision model cannot be reached.
    func answer(question: String, screenshot: Data, mimeType: String) async throws -> String
}
