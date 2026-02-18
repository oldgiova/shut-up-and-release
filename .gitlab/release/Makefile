# Release management targets
# Usage from repo root: make -f .gitlab/release/Makefile <target>

# Paths relative to repo root
REPO_ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null || echo "../..")
SCRIPTS_DIR := $(REPO_ROOT)/.gitlab/release

# Detect current context
CURRENT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
CURRENT_VERSION := $(shell git tag --sort=-version:refname 2>/dev/null | head -n 1 | sed 's/^v//' || echo "0.0.0")
PRERELEASE_CONFIG := $(shell jq -r '.prerelease // false' $(REPO_ROOT)/release-please-config.json 2>/dev/null || echo "unknown")
PRERELEASE_TYPE := $(shell jq -r '."prerelease-type" // "rc"' $(REPO_ROOT)/release-please-config.json 2>/dev/null || echo "rc")

# Required for GitHub operations
export GITHUB_REPO_URL
export GITHUB_TOKEN

.PHONY: help
help:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  RELEASE MANAGEMENT"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "Main Workflow:"
	@echo "  make release-pr                              Create release PR"
	@echo "  (review and merge PR on GitHub)"
	@echo "  make release-publish                         Tag + Push + GitHub Release"
	@echo ""
	@echo "Advanced:"
	@echo "  make release-pr PRERELEASE=true              Force RC release PR"
	@echo "  make release-pr PRERELEASE=false             Force stable release PR"
	@echo "  make release-promote                         Promote latest RC/saas to stable"
	@echo "  make release-promote RC_TAG=vX.Y.Z-rc.2      Promote specific tag to stable"
	@echo ""
	@echo "Helper Commands:"
	@echo "  make release-version-show                    Show next version (dry-run)"
	@echo "  make release-version-show PRERELEASE=true    Show next RC version"
	@echo "  make release-status                          Show current release status"
	@echo "  make release-diagnose                        Run diagnostic to debug issues"
	@echo ""
	@echo "Current Status:"
	@echo "  Branch:          $(CURRENT_BRANCH)"
	@echo "  Version:         $(CURRENT_VERSION)"
	@echo "  Prerelease mode: $(PRERELEASE_CONFIG)"
	@echo "  Prerelease type: $(PRERELEASE_TYPE)"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

.PHONY: release-status
release-status:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  CURRENT RELEASE STATUS"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "Repository:"
	@echo "  Branch:          $(CURRENT_BRANCH)"
	@echo "  Latest tag:      $(CURRENT_VERSION)"
	@echo "  Prerelease mode: $(PRERELEASE_CONFIG)"
	@echo "  Prerelease type: $(PRERELEASE_TYPE)"
	@echo ""
	@echo "Configuration:"
	@echo "  Config file:  release-please-config.json"
	@echo "  Version from: git tags (single source of truth)"
	@echo ""
	@echo "Recent Tags:"
	@git tag --sort=-version:refname 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (no tags found)"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

.PHONY: release-pr
release-pr:
	@echo "Creating release PR..."
	@cd $(REPO_ROOT) && if [ -n "$(PRERELEASE)" ]; then \
		if [ "$(PRERELEASE)" = "true" ]; then \
			echo "→ Forcing prerelease mode (override config)"; \
			$(SCRIPTS_DIR)/pr.sh --prerelease; \
		else \
			echo "→ Forcing stable mode (override config)"; \
			$(SCRIPTS_DIR)/pr.sh --no-prerelease; \
		fi \
	else \
		echo "→ Using prerelease setting from config: $(PRERELEASE_CONFIG)"; \
		$(SCRIPTS_DIR)/pr.sh; \
	fi

.PHONY: release-publish
release-publish:
	@echo "Publishing release (tag + push + GitHub release)..."
	@cd $(REPO_ROOT) && $(SCRIPTS_DIR)/publish.sh

.PHONY: release-promote
release-promote:
	@if [ -n "$(RC_TAG)" ]; then \
		echo "Promoting $(RC_TAG) to stable..."; \
		cd $(REPO_ROOT) && $(SCRIPTS_DIR)/promote.sh $(RC_TAG); \
	else \
		echo "Promoting latest prerelease to stable..."; \
		cd $(REPO_ROOT) && $(SCRIPTS_DIR)/promote.sh; \
	fi

.PHONY: release-github
release-github:
	@if [ -z "$(TAG)" ]; then \
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
		echo "  ERROR: TAG required"; \
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
		echo ""; \
		echo "Usage: make release-github TAG=v4.1.0"; \
		echo ""; \
		echo "Recent tags:"; \
		git tag --sort=-version:refname | head -5 | sed 's/^/  /' || echo "  (none found)"; \
		echo ""; \
		exit 1; \
	fi
	@echo "Creating GitHub release for $(TAG)..."
	@cd $(REPO_ROOT) && $(SCRIPTS_DIR)/release.sh $(TAG)

.PHONY: release-version-show
release-version-show:
	@echo "Analyzing commits to determine next version..."
	@echo ""
	@cd $(REPO_ROOT) && if [ -n "$(PRERELEASE)" ]; then \
		if [ "$(PRERELEASE)" = "true" ]; then \
			$(SCRIPTS_DIR)/version.sh --prerelease --dry-run --preview; \
		else \
			$(SCRIPTS_DIR)/version.sh --no-prerelease --dry-run --preview; \
		fi \
	else \
		$(SCRIPTS_DIR)/version.sh --dry-run --preview; \
	fi

.PHONY: release-diagnose
release-diagnose:
	@cd $(REPO_ROOT) && $(SCRIPTS_DIR)/diagnose.sh

# Validation target (run in CI)
.PHONY: release-validate
release-validate:
	@echo "Validating release configuration..."
	@test -f $(REPO_ROOT)/release-please-config.json || (echo "ERROR: Config file missing"; exit 1)
	@jq empty $(REPO_ROOT)/release-please-config.json 2>/dev/null || (echo "ERROR: Invalid config JSON"; exit 1)
	@git rev-parse --git-dir >/dev/null 2>&1 || (echo "ERROR: Not a git repository"; exit 1)
	@echo "✓ Release configuration valid"
