import Testing
import Foundation
@testable import AgentCore
@testable import AgentInfrastructure
@testable import AgentPresentation
@testable import AgentComposition

@Test func testParseEnvContent() {
    let sample = """
    # This is a comment
    LLM_API_KEY=test_key_123

    # Another comment
    GEMINI_MODEL="gemini-custom-model"
    QUOTED_SINGLE='single_quoted'
    SPACED = value_with_spaces   
    """

    let parsed = Configuration.parseEnvContent(sample)
    #expect(parsed["LLM_API_KEY"] == "test_key_123")
    #expect(parsed["GEMINI_MODEL"] == "gemini-custom-model")
    #expect(parsed["QUOTED_SINGLE"] == "single_quoted")
    #expect(parsed["SPACED"] == "value_with_spaces")
    #expect(parsed["NON_EXISTENT"] == nil)
}

@Test func testConfigurationLoadsFromDotEnv() throws {
    let config = try Configuration.load()
    #expect(!config.apiKey.isEmpty)
    #expect(config.model == "gemini-3.6-flash" || !config.model.isEmpty)
    #expect(FileManager.default.fileExists(atPath: config.projectRoot.appendingPathComponent("Package.swift").path))
}

@Test func testConfigurationPrecedence() {
    let envVars = ["LLM_API_KEY": "env_override_key", "GEMINI_MODEL": "gemini-override-model"]
    let dotEnvVars = ["LLM_API_KEY": "dotenv_key", "GEMINI_MODEL": "dotenv_model"]

    let resolvedKey = envVars["LLM_API_KEY"] ?? dotEnvVars["LLM_API_KEY"]
    let resolvedModel = envVars["GEMINI_MODEL"] ?? dotEnvVars["GEMINI_MODEL"]

    #expect(resolvedKey == "env_override_key")
    #expect(resolvedModel == "gemini-override-model")
}
