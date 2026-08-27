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

    func testPRContextMenuRunsAnalysisWithoutMarkFailure() {
        let app = launch(with: "--ui-testing-browser-pr-actions")
        let window = app.windows["PR Actions"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 8),
            "The deterministic PR action fixture should open"
        )

        let rowTitle = app.staticTexts["UI fixture failed check"]
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 3), "The failed PR fixture should render")
        rowTitle.rightClick()
        XCTAssertTrue(app.menuItems["Analyze CI Failure"].exists)
        XCTAssertFalse(app.menuItems["Mark Failure"].exists)
        XCTAssertTrue(app.menuItems["Run Skill"].exists)
        XCTAssertTrue(app.menuItems["Rerun Failed CI"].exists)
        XCTAssertTrue(
            app.menuItems["Install Tampermonkey Userscript in Browser…"].exists,
            "An unpaired client should get a browser setup action from the PR context menu"
        )


        rowTitle.rightClick()
        let analyze = app.menuItems["Analyze CI Failure"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 2))
        analyze.click()

        let analysis = app.staticTexts["pr-action-analysis"]
        XCTAssertTrue(analysis.waitForExistence(timeout: 2))
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'Needs investigation'"),
            object: analysis
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [completed], timeout: 5),
            .completed,
            "Analyze CI Failure must execute the Skill and publish its result"
        )

        rowTitle.rightClick()
        XCTAssertTrue(
            app.menuItems["View CI Analysis"].waitForExistence(timeout: 2),
            "Completed analysis should add a View CI Analysis action"
        )
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
        XCTAssertFalse(app.menuItems["Analyze CI Failure"].exists)
        XCTAssertFalse(app.menuItems["Mark Failure"].exists)
        XCTAssertFalse(app.menuItems["Rerun Failed CI"].exists)

        runSkill.hover()
        let explainFailure = app.menuItems["Explain CI Failure"]
        XCTAssertTrue(
            explainFailure.waitForExistence(timeout: 2),
            "Pull-request Skills must remain available when CI passes"
        )
    }


    private func launch(with argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [argument]
        app.launch()
        return app
    }
}