import Foundation

public struct ScenarioCatalog: Sendable {
    public static let shared = ScenarioCatalog()

    public let scenarios: [SafeScenario]

    public init(scenarios: [SafeScenario]) {
        self.scenarios = scenarios
    }

    public init() {
        self.scenarios = [
            SafeScenario(
                id: "SCENARIO-LANG-SHEET",
                name: "Open & Dismiss Language Selection Sheet",
                purpose: "Verify opening the language selection modal sheet from the header dropdown and restoring the screen via the explicit close button.",
                initialStateRequirement: "Active screen is 'Log In UAT'. Language dropdown button ('change-language-dropdown-button' / 'English') must be visible, enabled, and hittable.",
                expectedPostActionState: "Language modal bottom sheet appears presenting 'Language' title, close button ('close_var_1'), and language options.",
                changesUIState: true,
                actionStep: ScenarioStep(
                    id: "step_open_lang_sheet",
                    name: "Open Language Sheet",
                    description: "Tap header language dropdown button ('English')",
                    toolName: "tap_element",
                    locator: ScenarioLocator(
                        role: "button",
                        identifier: "change-language-dropdown-button",
                        label: "English"
                    ),
                    requiresApproval: true,
                    verification: ScenarioStepVerification(
                        description: "Language sheet modal is presented",
                        requiredElements: [
                            ScenarioExpectedElement(
                                role: "button",
                                identifier: "close_var_1",
                                label: "close_var_1",
                                requireNonZeroBounds: false,
                                requireEnabled: true,
                                requireHittable: true
                            )
                        ]
                    )
                ),
                teardownStep: ScenarioStep(
                    id: "step_dismiss_lang_sheet",
                    name: "Dismiss Language Sheet",
                    description: "Tap modal close button ('close_var_1')",
                    toolName: "tap_element",
                    locator: ScenarioLocator(
                        role: "button",
                        identifier: "close_var_1",
                        label: "close_var_1"
                    ),
                    requiresApproval: true,
                    verification: ScenarioStepVerification(
                        description: "Language sheet modal is dismissed and baseline restored",
                        requiredElements: [
                            ScenarioExpectedElement(
                                role: "button",
                                identifier: "change-language-dropdown-button",
                                label: "English",
                                requireNonZeroBounds: false
                            )
                        ],
                        forbiddenElements: [
                            ScenarioExpectedElement(
                                role: "button",
                                identifier: "close_var_1",
                                label: "close_var_1",
                                requireNonZeroBounds: false
                            )
                        ]
                    )
                )
            ),
            SafeScenario(
                id: "SCENARIO-INSPECT-LOGIN-SCREEN",
                name: "Verify Initial Login Screen Elements",
                purpose: "Read-only inspection asserting the presence, roles, and non-empty bounds of login-title, company-logo, change-language-dropdown-button, app-version, and login-button without altering application or simulator state.",
                initialStateRequirement: "Application is in runningForeground state on the initial screen with header and login form visible.",
                expectedPostActionState: "All baseline elements confirmed present with non-empty bounds; screen state remains strictly unchanged (zero mutation, no teardown required).",
                changesUIState: false,
                actionStep: ScenarioStep(
                    id: "step_inspect_login_screen",
                    name: "Inspect & Assert Baseline Elements",
                    description: "Execute read-only XCTest to assert presence and geometry of baseline elements without state mutation",
                    toolName: "inspect_elements",
                    locator: ScenarioLocator(
                        role: "staticText",
                        identifier: "login-title",
                        label: "Log In UAT"
                    ),
                    requiresApproval: true
                ),
                teardownStep: nil,
                expectedElements: [
                    ScenarioExpectedElement(role: "staticText", identifier: "login-title", label: "Log In UAT", requireNonZeroBounds: true),
                    ScenarioExpectedElement(role: "image", identifier: "company-logo", label: "company_logo", requireNonZeroBounds: true),
                    ScenarioExpectedElement(role: "button", identifier: "change-language-dropdown-button", label: "English", requireNonZeroBounds: true, requireEnabled: true, requireHittable: true),
                    ScenarioExpectedElement(role: "staticText", identifier: "app-version", label: "1.0", requireNonZeroBounds: true),
                    ScenarioExpectedElement(role: "button", identifier: "login-button", label: "Log In", requireNonZeroBounds: true)
                ]
            ),
            SafeScenario(
                id: "SCENARIO-TOGGLE-PASSWORD-VISIBILITY",
                name: "Toggle Password Field Visibility Icon",
                purpose: "Verify that tapping the password visibility eye icon updates presentation without submitting credentials or mutating persistent state.",
                initialStateRequirement: "Active screen is 'Log In UAT'. Password eye icon button ('password-textfield' / 'remove_red_eye') must be visible and hittable.",
                expectedPostActionState: "Password field eye icon presentation toggles.",
                changesUIState: true,
                actionStep: ScenarioStep(
                    id: "step_toggle_password_eye",
                    name: "Toggle Visibility",
                    description: "Tap password visibility eye icon button ('remove_red_eye')",
                    toolName: "tap_element",
                    locator: ScenarioLocator(
                        role: "button",
                        identifier: "password-textfield",
                        label: "remove_red_eye"
                    ),
                    requiresApproval: true
                ),
                teardownStep: ScenarioStep(
                    id: "step_restore_password_eye",
                    name: "Restore Visibility Toggle",
                    description: "Tap password visibility eye icon button again to restore initial state",
                    toolName: "tap_element",
                    locator: ScenarioLocator(
                        role: "button",
                        identifier: "password-textfield",
                        label: "remove_red_eye"
                    ),
                    requiresApproval: true
                )
            )
        ]
    }

    public func findScenario(by id: String) -> SafeScenario? {
        scenarios.first { $0.id == id }
    }
}
