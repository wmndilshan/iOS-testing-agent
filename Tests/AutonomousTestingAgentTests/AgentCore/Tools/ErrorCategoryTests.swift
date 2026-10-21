import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Suite("Error taxonomy")
struct ErrorCategoryTests {

    @Test func testTheTaxonomyCoversTheRequiredCategories() {
        let raw = Set(ErrorCategory.allCases.map(\.rawValue))
        for name in ["validation", "authorization", "approval", "observation", "targetNotFound", "targetNotHittable", "toolUnavailable",
                     "execution", "xctest", "simulator", "network", "llm", "parsing", "verification", "timeout", "persistence", "security", "configuration"] {
            #expect(raw.contains(name), "\(name)")
        }
    }

    @Test func testDriverErrorsMapToTargetAndObservationCategories() {
        #expect(DriverError.elementNotFound("e").errorCategory == .targetNotFound)
        #expect(DriverError.elementNotHittable("e").errorCategory == .targetNotHittable)
        #expect(DriverError.staleSnapshot(requested: "a", current: "b").errorCategory == .observation)
        #expect(DriverError.actionFailed("x").errorCategory == .xctest)
        #expect(DriverError.simulatorNotAvailable("x").errorCategory == .simulator)
    }

    @Test func testToolAndProposalErrorsMapToPolicyCategories() {
        #expect(ToolRegistryError.toolNotFound("t").errorCategory == .toolUnavailable)
        #expect(ToolRegistryError.authorizationRequired("t").errorCategory == .authorization)
        #expect(ToolRegistryError.invalidArguments("x").errorCategory == .validation)
        #expect(LLMProposalPipelineError.duplicateProposal(reason: "x").errorCategory == .validation)
    }

    @Test func testProviderErrorsMapToNeutralCategories() {
        #expect(LLMNetworkError.timeout("t").errorCategory == .timeout)
        #expect(LLMNetworkError.rateLimited(statusCode: 429, retryAfter: nil, message: "m").errorCategory == .network)
        #expect(LLMNetworkError.unauthorized(statusCode: 401, message: "m").errorCategory == .configuration)
        #expect(LLMError.decodingError("x").errorCategory == .parsing)
    }

    @Test func testUnclassifiedErrorsFallBackToExecution() {
        struct Plain: Error {}
        #expect(ErrorCategory.of(Plain()) == .execution)
        #expect(ErrorCategory.of(DriverError.elementNotFound("e")) == .targetNotFound)
    }
}
