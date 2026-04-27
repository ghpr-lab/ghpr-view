.PHONY: build build-cli build-release run clean install uninstall open lint format help

# Project configuration
PROJECT_NAME = PRDashboard
SCHEME = PRDashboard
CLI_SCHEME = ghpr
BUILD_DIR = build
DERIVED_DATA = $(BUILD_DIR)/DerivedData
APP_NAME = $(PROJECT_NAME).app
CLI_NAME = ghpr
INSTALL_DIR = /Applications

# Xcode build settings
XCODE_PROJECT = $(PROJECT_NAME).xcodeproj
XCODE_FLAGS = -project $(XCODE_PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA)

# Default target
all: build

## Build targets

build: ## Build debug version
	xcodebuild $(XCODE_FLAGS) -configuration Debug build

build-cli: ## Build ghpr command-line tool
	xcodebuild -project $(XCODE_PROJECT) -scheme $(CLI_SCHEME) -derivedDataPath $(DERIVED_DATA) -configuration Debug build
	@CLI_PATH=$$(find $(DERIVED_DATA) -name "$(CLI_NAME)" -type f | head -1); \
	if [ -n "$$CLI_PATH" ]; then \
		echo "Built $$CLI_PATH"; \
	fi

build-release: ## Build release version
	xcodebuild $(XCODE_FLAGS) -configuration Release build

archive: ## Create release archive
	xcodebuild $(XCODE_FLAGS) -configuration Release \
		-archivePath $(BUILD_DIR)/$(PROJECT_NAME).xcarchive archive

## Run targets

run: build ## Build and run the app
	@APP_PATH=$$(find $(DERIVED_DATA) -name "$(APP_NAME)" -type d | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		open "$$APP_PATH"; \
	else \
		echo "Error: Could not find $(APP_NAME)"; \
		exit 1; \
	fi

run-release: build-release ## Build release and run
	@APP_PATH=$$(find $(DERIVED_DATA) -name "$(APP_NAME)" -type d | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		open "$$APP_PATH"; \
	else \
		echo "Error: Could not find $(APP_NAME)"; \
		exit 1; \
	fi

## Installation targets

install: build-release ## Install to /Applications
	@APP_PATH=$$(find $(DERIVED_DATA) -name "$(APP_NAME)" -type d | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		echo "Installing to $(INSTALL_DIR)/$(APP_NAME)..."; \
		rm -rf "$(INSTALL_DIR)/$(APP_NAME)"; \
		cp -R "$$APP_PATH" "$(INSTALL_DIR)/"; \
		echo "Installed successfully!"; \
	else \
		echo "Error: Build the app first with 'make build-release'"; \
		exit 1; \
	fi

uninstall: ## Remove from /Applications
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME)" ]; then \
		echo "Removing $(INSTALL_DIR)/$(APP_NAME)..."; \
		rm -rf "$(INSTALL_DIR)/$(APP_NAME)"; \
		echo "Uninstalled successfully!"; \
	else \
		echo "$(APP_NAME) is not installed"; \
	fi

## Clean targets

clean: ## Clean build artifacts
	xcodebuild $(XCODE_FLAGS) clean
	rm -rf $(BUILD_DIR)

clean-all: clean ## Clean everything including Xcode caches
	rm -rf ~/Library/Developer/Xcode/DerivedData/$(PROJECT_NAME)-*

## Development targets

dev: ## Build with local signing (requires Apple ID in Xcode)
	./dev.sh

dev-run: ## Build with local signing and run
	./dev.sh --run

open: ## Open project in Xcode
	open $(XCODE_PROJECT)

lint: ## Run SwiftLint (if installed)
	@if command -v swiftlint &> /dev/null; then \
		swiftlint lint --path $(PROJECT_NAME); \
	else \
		echo "SwiftLint not installed. Install with: brew install swiftlint"; \
	fi

format: ## Format code with SwiftFormat (if installed)
	@if command -v swiftformat &> /dev/null; then \
		swiftformat $(PROJECT_NAME); \
	else \
		echo "SwiftFormat not installed. Install with: brew install swiftformat"; \
	fi

## Utility targets

check: ## Check if project builds without errors
	xcodebuild $(XCODE_FLAGS) -configuration Debug build -quiet

loc: ## Count lines of code
	@echo "Lines of Swift code:"
	@find $(PROJECT_NAME) -name "*.swift" -exec cat {} \; | wc -l

files: ## List all Swift files
	@find $(PROJECT_NAME) -name "*.swift" | sort

## Help

help: ## Show this help
	@echo "PRDashboard - GitHub PR Menu Bar App"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
