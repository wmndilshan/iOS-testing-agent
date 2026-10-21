import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
