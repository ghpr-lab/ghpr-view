import XCTest

final class BrowserIntegrationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsKeepsBrowserAndSkillDetailsCollapsedUntilRequested() {
        let app = launch(with: "--ui-testing-browser-settings")
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings window should open in UI test mode")
        XCTAssertTrue(
            app.staticTexts["Browser Integration"].waitForExistence(timeout: 3),
            "Settings must expose Browser Integration"
        )
        let bridgeStatus = app.descendants(matching: .any)
            .matching(identifier: "browser-bridge-status")
            .matching(NSPredicate(format: "value CONTAINS 'Running'"))
            .firstMatch
        XCTAssertTrue(
            bridgeStatus.waitForExistence(timeout: 5),
            "The compact Browser Integration summary should expose the live bridge state"
        )
        let userscriptReminder = app.descendants(matching: .any)
            .matching(identifier: "userscript-reminder")
            .firstMatch
        XCTAssertTrue(
            userscriptReminder.waitForExistence(timeout: 2),
            "An unpaired userscript should produce a soft setup reminder"
        )
        XCTAssertTrue(
            app.buttons["Install Userscript in Browser"].exists,
            "Browser-bound actions should name their destination"
        )

        let browserDetails = app.buttons["browser-integration-details-toggle"]
        XCTAssertTrue(browserDetails.waitForExistence(timeout: 3))
        XCTAssertEqual(browserDetails.value as? String, "Collapsed")
        XCTAssertFalse(
            app.buttons["revoke-dev.ghpr.ui-test-client"].exists,
            "Paired-client management should be hidden by default"
        )
        XCTAssertFalse(
            app.buttons["open-browser-test"].exists,
            "Browser Test is secondary and should stay inside collapsed details"
        )

        browserDetails.click()
        XCTAssertEqual(browserDetails.value as? String, "Expanded")
        let revoke = app.buttons["revoke-dev.ghpr.ui-test-client"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 3), "Expanded details must expose paired-client management")
        XCTAssertTrue(
            app.buttons["open-browser-test"].waitForExistence(timeout: 2),
            "Expanded connection details should expose Browser Test"
        )
        revoke.click()
        XCTAssertTrue(
            app.staticTexts["Revoked"].waitForExistence(timeout: 2),
            "Revocation must update the settings UI immediately"
        )

        let builderDetails = app.buttons["skill-builder-details-toggle"]
        XCTAssertTrue(builderDetails.waitForExistence(timeout: 3))
        XCTAssertEqual(builderDetails.value as? String, "Collapsed")
        XCTAssertTrue(
            app.buttons["Open Workbench in Browser"].exists,
            "Skill Builder should set a browser handoff expectation"
        )
    }

    func testCodingAgentRuntimeSelectsAgentBeforeModelConfiguration() {
        let app = launch(with: "--ui-testing-browser-settings")
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings window should open in UI test mode")
        XCTAssertTrue(
            app.staticTexts["Coding Agent Runtime"].waitForExistence(timeout: 3),
            "Settings must expose the coding agent runtime section"
        )

        let runtimeToggle = app.buttons["agent-runtime-toggle"]
        XCTAssertTrue(runtimeToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(runtimeToggle.value as? String, "Collapsed")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "agent-runtime-agent-picker")
                .firstMatch
                .exists,
            "Model configuration stays behind the compact summary"
        )

        runtimeToggle.click()
        XCTAssertEqual(runtimeToggle.value as? String, "Expanded")
        let agentPicker = app.descendants(matching: .any)
            .matching(identifier: "agent-runtime-agent-picker")
            .firstMatch
        XCTAssertTrue(
            agentPicker.waitForExistence(timeout: 3),
            "The coding agent is chosen before its model"
        )
        XCTAssertEqual(agentPicker.value as? String, "Claude Code")
        XCTAssertTrue(
            app.buttons["agent-runtime-refresh"].waitForExistence(timeout: 10),
            "Claude Code offers a CLI-backed model list action"
        )
        XCTAssertFalse(
            app.textFields["agent-model-field"].exists,
            "A listed agent configures its model through a picker"
        )

        settings.radioButtons["OMP"].click()
        XCTAssertEqual(agentPicker.value as? String, "OMP")
        let ompModel = app.textFields["agent-model-field"]
        XCTAssertTrue(
            ompModel.waitForExistence(timeout: 3),
            "OMP configures its model through a free-form field"
        )
        XCTAssertFalse(
            app.buttons["agent-runtime-refresh"].exists,
            "OMP exposes no CLI model listing"
        )

        ompModel.click()
        ompModel.typeText("opus")
        app.buttons["Apply Model"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "agent-runtime-status")
                .matching(
                    NSPredicate(format: "label CONTAINS 'OMP · opus' OR value CONTAINS 'OMP · opus'")
                )
                .firstMatch
                .waitForExistence(timeout: 3),
            "The compact summary reports the selected agent and its pinned model"
        )
    }

    func testPairingRequiresExplicitElevatedScopeApproval() {
        let app = launch(with: "--ui-testing-browser-pairing")
        let pairingWindow = app.windows["Browser Client Permission"]
        XCTAssertTrue(
            pairingWindow.waitForExistence(timeout: 8),
            "A browser pairing request must open a native permission window"
        )
        let clientName = app.staticTexts["pairing-client-name"]
        XCTAssertTrue(clientName.waitForExistence(timeout: 3))
        XCTAssertTrue((clientName.value as? String)?.contains("Team CI Helper") == true)

        let elevatedScope = app.checkBoxes["pairing-scope-skill:run"]
        XCTAssertTrue(elevatedScope.exists)
        let scopeValue = elevatedScope.value
        XCTAssertTrue(
            (scopeValue as? Int) == 0 || (scopeValue as? String) == "0",
            "Elevated permissions must not be approved by default"
        )
        elevatedScope.click()
        app.buttons["allow-pairing"].click()
        XCTAssertTrue(
            pairingWindow.waitForNonExistence(timeout: 3),
            "Approved pairing should close the native permission window"
        )
    }

    func testPermissionUpgradeRequiresExplicitRequiredScope() {
        let app = launch(with: "--ui-testing-browser-permission-upgrade")
        let pairingWindow = app.windows["Browser Client Permission"]
        XCTAssertTrue(pairingWindow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Required for this action"].waitForExistence(timeout: 3))
        let elevatedScope = app.checkBoxes["pairing-scope-skill:run"]
        XCTAssertTrue(elevatedScope.exists)
        XCTAssertTrue((elevatedScope.value as? Int) == 0 || (elevatedScope.value as? String) == "0")
        XCTAssertFalse(app.buttons["allow-pairing"].isEnabled)
        elevatedScope.click()
        XCTAssertTrue(app.buttons["allow-pairing"].isEnabled)
        app.buttons["allow-pairing"].click()
        XCTAssertTrue(pairingWindow.waitForNonExistence(timeout: 3))
    }

    func testPRContextMenuRoutesAnalysisToChecks() {
        let app = launch(with: "--ui-testing-browser-pr-actions")
        let window = app.windows["PR Actions"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 8),
            "The deterministic PR action fixture should open"
        )

        let rowTitle = app.staticTexts["UI fixture failed check"]
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 3), "The failed PR fixture should render")
        rowTitle.rightClick()
        XCTAssertTrue(app.menuItems["Analyze CI Failure in Checks"].exists)
        XCTAssertFalse(app.menuItems["Mark Failure"].exists)
        XCTAssertTrue(app.menuItems["Run Skill"].exists)
        XCTAssertTrue(app.menuItems["Rerun Failed CI"].exists)
        XCTAssertTrue(
            app.menuItems["Install Tampermonkey Userscript in Browser…"].exists,
            "An unpaired client should get a browser setup action from the PR context menu"
        )
        XCTAssertFalse(app.menuItems["Analyze CI Failure"].exists)
    }

    func testPassingPRContextMenuCanRunSkills() {
        let app = launch(with: "--ui-testing-browser-pr-actions-passing")
        let window = app.windows["PR Actions"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 8),
            "The deterministic passing PR fixture should open"
        )

        let rowTitle = app.staticTexts["UI fixture passing checks"]
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 3), "The passing PR fixture should render")
        rowTitle.rightClick()

        let runSkill = app.menuItems["Run Skill"]
        XCTAssertTrue(runSkill.exists, "Passing PRs must expose the Run Skill submenu")
        XCTAssertFalse(app.menuItems["Analyze CI Failure in Checks"].exists)
        XCTAssertFalse(app.menuItems["Mark Failure"].exists)
        XCTAssertFalse(app.menuItems["Rerun Failed CI"].exists)

        runSkill.hover()
        let reviewPR = app.menuItems["Review PR"]
        XCTAssertTrue(
            reviewPR.waitForExistence(timeout: 2),
            "The exact-revision PR Review Skill must remain available when CI passes"
        )
    }

    func testPRRowHoverShowsDetailPanel() {
        let app = launch(with: "--ui-testing-browser-pr-actions-passing")
        let window = app.windows["PR Actions"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 8),
            "The deterministic passing PR fixture should open"
        )

        let rowTitle = app.staticTexts["UI fixture passing checks"]
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 3), "The passing PR fixture should render")
        rowTitle.hover()

        XCTAssertTrue(
            app.staticTexts["Base"].waitForExistence(timeout: 3),
            "Hovering a PR item should reveal its detail panel"
        )
    }

    func testRunSkillSubmenuSurvivesExtensionUpdate() {
        let app = launch(with: "--ui-testing-browser-pr-actions-updating")
        XCTAssertTrue(
            app.windows["PR Actions"].waitForExistence(timeout: 8),
            "The deterministic updating PR fixture should open."
        )

        let rowTitle = app.staticTexts["UI fixture passing checks"]
        XCTAssertTrue(
            rowTitle.waitForExistence(timeout: 3),
            "The passing PR fixture should render before opening its context menu."
        )
        rowTitle.rightClick()

        let runSkill = app.menuItems["Run Skill"]
        XCTAssertTrue(runSkill.exists, "The Run Skill submenu must be available.")
        runSkill.hover()

        let reviewPR = app.menuItems["Review PR"]
        XCTAssertTrue(
            reviewPR.waitForExistence(timeout: 2),
            "The Run Skill submenu must open before the fixture publishes an update."
        )
        XCTAssertTrue(
            app.windows["PR Actions Updated"].waitForExistence(timeout: 2),
            "The fixture must publish an extension update while the submenu is open."
        )
        XCTAssertTrue(
            runSkill.exists,
            "The parent context-menu item must remain visible after the update."
        )
        XCTAssertTrue(
            reviewPR.exists,
            "The open Run Skill submenu must remain visible after the update."
        )
    }

    func testGitHubSurfaceV2DefaultsOnInConnectionDetails() throws {
        let app = launch(with: "--ui-testing-browser-settings")
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings window should open in UI test mode")

        let browserDetails = app.buttons["browser-integration-details-toggle"]
        XCTAssertTrue(browserDetails.waitForExistence(timeout: 3))
        browserDetails.click()
        XCTAssertEqual(browserDetails.value as? String, "Expanded")

        let v2Toggle = app.descendants(matching: .any)
            .matching(identifier: "github-surface-v2-toggle")
            .firstMatch
        XCTAssertTrue(
            v2Toggle.waitForExistence(timeout: 3),
            "The GitHub-native surfaces rollback toggle must be present in connection details"
        )
        XCTAssertTrue(
            (v2Toggle.value as? Int) == 1 || (v2Toggle.value as? String) == "1",
            "GitHub-native surfaces must be enabled by default"
        )
    }

    func testGitHubSurfaceV2RollbackToggleRestoresLegacySurfaces() throws {
        let app = launch(with: "--ui-testing-browser-settings")
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings window should open in UI test mode")

        let browserDetails = app.buttons["browser-integration-details-toggle"]
        XCTAssertTrue(browserDetails.waitForExistence(timeout: 3))
        browserDetails.click()

        let v2Toggle = app.descendants(matching: .any)
            .matching(identifier: "github-surface-v2-toggle")
            .firstMatch
        XCTAssertTrue(
            v2Toggle.waitForExistence(timeout: 3),
            "The GitHub-native surfaces rollback toggle must be present in connection details"
        )
        XCTAssertTrue(
            (v2Toggle.value as? Int) == 1 || (v2Toggle.value as? String) == "1",
            "GitHub-native surfaces must start enabled before rollback is exercised"
        )

        v2Toggle.click()
        XCTAssertTrue(
            (v2Toggle.value as? Int) == 0 || (v2Toggle.value as? String) == "0",
            "Toggling rollback must disable GitHub-native surfaces"
        )

        v2Toggle.click()
        XCTAssertTrue(
            (v2Toggle.value as? Int) == 1 || (v2Toggle.value as? String) == "1",
            "Re-enabling the toggle must restore GitHub-native surfaces"
        )
    }

    func testConnectionDetailsShowsMissingOrAmbiguousSurfaceHealth() throws {
        let app = launch(with: "--ui-testing-browser-settings")
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings window should open in UI test mode")

        let browserDetails = app.buttons["browser-integration-details-toggle"]
        XCTAssertTrue(browserDetails.waitForExistence(timeout: 3))
        browserDetails.click()

        let healthSection = app.descendants(matching: .any)
            .matching(identifier: "surface-health-section")
            .firstMatch
        XCTAssertTrue(
            healthSection.waitForExistence(timeout: 3),
            "A deterministic surface-health fixture must be present in connection details"
        )

        let healthRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'surface-health-row'"))
        XCTAssertGreaterThan(
            healthRows.count,
            0,
            "Connection details must list at least one current surface-health row"
        )

        let statuses = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH 'surface-health-row' " +
                        "AND (value CONTAINS[c] 'Missing' OR value CONTAINS[c] 'Ambiguous' " +
                        "OR label CONTAINS[c] 'Missing' OR label CONTAINS[c] 'Ambiguous')"
                )
            )
        XCTAssertGreaterThan(
            statuses.count,
            0,
            "Surface-health rows must surface Missing/Ambiguous states, not just Healthy ones"
        )

        let warning = app.descendants(matching: .any)
            .matching(identifier: "browser-slot-health-warning")
            .firstMatch
        XCTAssertTrue(
            warning.waitForExistence(timeout: 3),
            "Unhealthy GitHub-native surfaces must roll up into the browser status warning, not read as Ready"
        )
    }

    func testRevokedPairingRemovesClientBrowserActions() {
        let app = launch(with: "--ui-testing-browser-settings")
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "Settings window should open in UI test mode")

        let browserDetails = app.buttons["browser-integration-details-toggle"]
        XCTAssertTrue(browserDetails.waitForExistence(timeout: 3))
        browserDetails.click()
        let pairedCountBefore = app.staticTexts["paired-client-count"]
        XCTAssertTrue(pairedCountBefore.waitForExistence(timeout: 3))
        XCTAssertEqual(pairedCountBefore.value as? String, "1 paired")

        let revoke = app.buttons["revoke-dev.ghpr.ui-test-client"]
        XCTAssertTrue(revoke.waitForExistence(timeout: 3), "The paired client must expose a Revoke action")
        revoke.click()

        XCTAssertTrue(
            app.staticTexts["Revoked"].waitForExistence(timeout: 2),
            "Revocation must update the settings UI immediately"
        )
        XCTAssertFalse(
            revoke.exists,
            "Revoking a client must remove its browser-driven Revoke action"
        )
        let pairedCountAfter = app.staticTexts["paired-client-count"]
        XCTAssertTrue(pairedCountAfter.waitForExistence(timeout: 3))
        XCTAssertEqual(pairedCountAfter.value as? String, "0 paired")


    }


    private func launch(with argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [argument]
        app.launch()
        return app
    }
}