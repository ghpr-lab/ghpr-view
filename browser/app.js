(function ghprLocalUIModule(global) {
  "use strict";

  const STAGES = [
    ["Draft", "Define contract"],
    ["Validate Contract", "Check structure"],
    ["Run Fixture", "Verify result"],
    ["Preview", "Inspect surfaces"],
    ["Review Permissions", "Approve elevation"],
    ["Install", "Make available"]
  ];

  const RUN_STEPS = [
    { id: "queue", name: "Queue run", messages: ["Queued"] },
    { id: "context", name: "Prepare strict context", messages: ["Preparing strict context"] },
    { id: "runtime", name: "Start Skill runtime", messages: ["Starting Skill runtime"] },
    {
      id: "execute",
      name: "Execute Skill",
      messages: ["Executing Skill", "Receiving Agent output"]
    },
    { id: "finalize", name: "Finalize result", messages: ["Finalizing result"] },
    {
      id: "complete",
      name: "Complete run",
      messages: ["Completed", "Cancelled", "Skill execution failed"]
    }
  ];

  const STEP_MARKERS = { running: "●", success: "✓", cancelled: "!", failed: "×" };

  const LOG_MARKERS = { queued: "○", running: "●", success: "✓", warning: "!", error: "×" };

  const EDITABLE_FILES = [
    ["ghpr.skill.yaml", "Manifest"],
    ["schemas/result.schema.json", "Result schema"],
    ["presentation/presentation.yaml", "Presentation"],
    ["browser/contributions.yaml", "Browser"],
    ["fixtures/expected-result.json", "Fixture"]
  ];

  const SLOT_LABELS = {
    "pr.header.actions": "PR header action",
    "pr.header.status": "PR header status",
    "pr.mergebox.after": "After merge box",
    "pr.conversation.after-checks": "After checks summary",
    "checks.summary.actions": "Checks summary action",
    "checks.run.trailing": "Workflow run trailing",
    "checks.job.trailing": "Check job trailing",
    "files.toolbar.actions": "Files toolbar action",
    "files.diff.line-decoration": "Diff line decoration"
  };

  const SCOPE_LABELS = {
    "pr:read": "Read current PR",
    "ci:read": "Read CI status",
    "analysis:read": "Read analysis results",
    "artifact:read": "Read Skill artifacts",
    "skill:list": "List configured Skills",
    "skill:run": "Run configured Skills",
    "skill:cancel": "Cancel Skill runs",
    "tag:read": "Read locally stored ghpr tags",
    "tag:write": "Change locally stored ghpr tags (not GitHub labels)",
    "ui:contribute": "Add GitHub page UI",
    "detail:open": "Open local analysis",
    "app:open": "Open ghpr-view"
  };

  class LocalAppError extends Error {
    constructor(message, status, code) {
      super(message);
      this.name = "LocalAppError";
      this.status = status;
      this.code = code;
    }
  }
  function element(document, tagName, options = {}, children = []) {
    const node = document.createElement(tagName);
    for (const [key, value] of Object.entries(options)) {
      if (value === null || value === undefined) continue;
      if (key === "className") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key === "dataset") Object.assign(node.dataset, value);
      else if (key === "onClick") node.addEventListener("click", value);
      else if (key === "onInput") node.addEventListener("input", value);
      else if (key === "onSubmit") node.addEventListener("submit", value);
      else if (key === "checked") node.checked = value;
      else if (key === "disabled") node.disabled = value;
      else if (key === "value") node.value = value;
      else node.setAttribute(key, value);
    }
    for (const child of Array.isArray(children) ? children : [children]) {
      if (child === null || child === undefined) continue;
      node.append(child.nodeType ? child : document.createTextNode(String(child)));
    }
    return node;
  }

  function appIcon(document, className) {
    return element(document, "img", {
      className,
      src: "/assets/app-icon.png",
      alt: "",
      "aria-hidden": "true",
      draggable: "false"
    });
  }

  function titleCase(value) {
    return String(value || "")
      .split("_")
      .map((part) => part ? part[0].toUpperCase() + part.slice(1) : "")
      .join(" ");
  }

  function percent(value) {
    return `${Math.round(Number(value || 0) * 100)}%`;
  }

  function queryToken(window) {
    return new URLSearchParams(window.location.search).get("cap") || "";
  }

  function tone(value) {
    if (value === "likely_flaky" || value === "warning" || value === "cancelled") return "warning";
    if (value === "likely_related" || value === "danger" || value === "failed") return "danger";
    if (value === "success" || value === "completed") return "success";
    return "analysis";
  }

  class LocalApp {
    constructor({ window, document, fetch: fetchImpl }) {
      this.window = window;
      this.document = document;
      this.fetch = fetchImpl || window.fetch.bind(window);
      this.root = document.getElementById("ghpr-app");
      this.page = document.body.dataset.ghprPage || "browser-test";
      this.capability = queryToken(window);
      this.workbench = {
        stage: 0,
        packagePath: null,
        activeFile: "ghpr.skill.yaml",
        files: {},
        preview: null,
        validation: null,
        capabilities: null,
        fixturePassed: false,
        permissionsReviewed: false,
        mode: "create",
        busy: false,
        error: null,
        notice: null,
        installed: false,
        discoveredSkills: [],
        discoveryLoaded: false,
        discoveryBusy: false,
        discoveryError: null,
      };
      this.runRefreshTimer = null;
      this.pairingStatusTimer = null;
      this.pairingCloseTimer = null;
      this.runStepState = new Map();
    }

    async request(path, options = {}) {
      const headers = { Accept: "application/json", ...(options.headers || {}) };
      if (this.capability) headers.Authorization = `Bearer ${this.capability}`;
      if (options.body && !headers["Content-Type"]) {
        headers["Content-Type"] = "application/json";
      }
      const response = await this.fetch(path, { ...options, headers });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new LocalAppError(
          payload.error?.message || `Request failed (${response.status})`,
          response.status,
          payload.error?.code || null
        );
      }
      return payload;
    }

    currentLocalPath() {
      return `${this.window.location.pathname}${this.window.location.search}`;
    }


    async start() {
      if (!this.root) return;
      try {
        if (["analysis", "run", "workbench", "github-preview", "browser-test"].includes(this.page)) {
          await this.requireCapability();
        }
        switch (this.page) {
        case "home":
          await this.renderHome();
          break;
        case "pairing":
          await this.renderPairing();
          break;
        case "analysis":
          await this.renderAnalysis();
          break;
        case "run":
          await this.renderRun();
          break;
        case "workbench":
          await this.renderWorkbenchStart();
          break;
        case "github-preview":
          this.renderGitHubPreview();
          break;
        default:
          await this.renderBrowserTest();
          break;
        }
      } catch (error) {
        this.renderFatal(error);
      }
    }
    async requireCapability() {
      const capability = await this.request("/api/v1/local-capability");
      const expectedKind = this.page === "analysis"
        ? "analysis"
        : this.page === "run" ? "run" : "workbench";
      const resourceID = this.page === "analysis" || this.page === "run"
        ? this.window.location.pathname.split("/").filter(Boolean).pop()
        : null;
      if (capability.kind !== expectedKind ||
          (resourceID !== null && capability.resource_id !== resourceID)) {
        throw new LocalAppError("This capability is for a different local page.", 403, "unauthorized");
      }
      return capability;
    }


    stop() {
      if (this.runRefreshTimer !== null) {
        this.window.clearTimeout(this.runRefreshTimer);
        this.runRefreshTimer = null;
      }
      if (this.pairingStatusTimer !== null) {
        this.window.clearTimeout(this.pairingStatusTimer);
        this.pairingStatusTimer = null;
      }
      if (this.pairingCloseTimer !== null) {
        this.window.clearTimeout(this.pairingCloseTimer);
        this.pairingCloseTimer = null;
      }
    }

    scheduleRunRefresh() {
      this.stop();
      this.runRefreshTimer = this.window.setTimeout(async () => {
        this.runRefreshTimer = null;
        if (this.window.closed || this.page !== "run") return;
        try {
          await this.renderRun();
        } catch (error) {
          this.renderFatal(error);
        }
      }, 2000);
    }

    clear() {
      this.root.replaceChildren();
    }

    frame({ active, title, eyebrow, actions = [] }) {
      this.clear();
      const d = this.document;
      this.root.dataset.ui = "github";
      const skipLink = element(d, "a", {
        className: "skip-link",
        href: "#main-content",
        text: "Skip to content"
      });
      const globalHeader = element(d, "header", { className: "app-header" }, [
        element(d, "div", { className: "global-brand" }, [
          appIcon(d, "brand-mark"),
          element(d, "strong", { text: "ghpr" }),
          element(d, "span", { className: "product-label", text: "Browser Bridge" })
        ]),
        element(d, "div", { className: "header-boundary" }, [
          element(d, "span", { className: "status-dot", "aria-hidden": "true" }),
          element(d, "code", { text: "127.0.0.1" }),
          element(d, "span", { text: "Loopback only" })
        ])
      ]);
      const navigation = element(
        d,
        "nav",
        { className: "repo-nav", "aria-label": "Local ghpr pages" },
        this.navigationItems()
      );
      for (const item of navigation.querySelectorAll("[data-page]")) {
        const selected = item.dataset.page === active;
        item.classList.toggle("active", selected);
        if (selected) item.setAttribute("aria-current", "page");
      }
      const repositoryHeader = element(d, "section", { className: "repo-header" }, [
        element(d, "div", { className: "repo-identity" }, [
          appIcon(d, "repo-icon"),
          element(d, "strong", { text: "ghpr" }),
          element(d, "span", { className: "repo-slash", text: "/" }),
          element(d, "span", { text: "Extension Platform" }),
          element(d, "span", { className: "visibility-pill", text: "Local" })
        ]),
        navigation
      ]);
      const actionBar = element(d, "div", { className: "page-actions" }, actions);
      const main = element(d, "main", { className: "page-main", id: "main-content" }, [
        element(d, "header", { className: "page-header" }, [
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: eyebrow }),
            element(d, "h1", { text: title })
          ]),
          actionBar
        ]),
        element(d, "div", { className: "page-content" })
      ]);
      this.root.append(skipLink, globalHeader, repositoryHeader, main);
      return main.querySelector(".page-content");
    }

    navigationItems() {
      const currentPath = this.currentLocalPath();
      if (this.page === "pairing") {
        return [this.navItem("pairing", "Pair client", "shield", null)];
      }
      if (this.page === "analysis" || this.page === "run") {
        const currentPage = this.page === "analysis" ? "analysis" : "run";
        const currentLabel = this.page === "analysis" ? "CI analysis" : "Skill run";
        return [this.navItem(currentPage, currentLabel, "pulse", currentPath)];
      }
      if (this.page === "home" || !this.capability) {
        return [this.navItem("home", "Overview", "home", "/ui")];
      }
      const suffix = `?cap=${encodeURIComponent(this.capability)}`;
      return [
        this.navItem("workbench", "Skill Workbench", "tools", `/ui/workbench${suffix}`),
        this.navItem("github-preview", "GitHub preview", "browser", `/ui/github-preview${suffix}`),
        this.navItem("browser-test", "Browser test", "shield", `/ui/browser-test${suffix}`)
      ];
    }
    safeGitHubReturnURL() {
      const value = new URLSearchParams(this.window.location.search).get("return");
      if (!value) return null;
      try {
        const target = new URL(value);
        if (target.protocol !== "https:" || target.hostname !== "github.com" ||
            target.port || target.username || target.password) return null;
        if (!/^\/[^/]+\/[^/]+\/(pull\/\d+(?:\/.*)?|actions\/runs\/\d+(?:\/.*)?)$/.test(target.pathname)) {
          return null;
        }
        return target.href;
      } catch (_) {
        return null;
      }
    }

    navItem(page, label, icon, href) {
      const glyph = {
        home: "⌂",
        pulse: "●",
        tools: "<>",
        browser: "▣",
        shield: "✓"
      }[icon] || "•";
      return element(this.document, href ? "a" : "div", {
        href,
        "aria-disabled": href ? null : "true",
        className: href ? "" : "disabled",
        dataset: { page }
      }, [
        element(this.document, "span", {
          className: `nav-icon ${icon}`,
          text: glyph,
          "aria-hidden": "true"
        }),
        element(this.document, "span", { text: label })
      ]);
    }

    renderFatal(error) {
      const content = this.frame({
        active: this.page,
        title: "Unable to load",
        eyebrow: "Browser Bridge"
      });
      const capabilityFailure = error?.status === 401 || error?.status === 403;
      const returnURL = this.safeGitHubReturnURL();
      const workbenchPage = ["workbench", "github-preview", "browser-test"].includes(this.page);
      const message = capabilityFailure && workbenchPage
        ? "Open ghpr → Settings → Skill Builder → Open Skill Workbench"
        : capabilityFailure
          ? "Reopen this page from GitHub to receive a fresh capability."
          : (error.message || String(error));
      const actions = returnURL && capabilityFailure
        ? [element(this.document, "a", { className: "button primary", href: returnURL, text: "Return to GitHub" })]
        : [];
      content.append(element(this.document, "section", { className: "empty-card danger-border" }, [
        element(this.document, "span", { className: "large-icon", text: "!" }),
        element(this.document, "h2", { text: capabilityFailure ? "Local capability unavailable" : "Unable to load" }),
        element(this.document, "p", { text: message }),
        ...actions
      ]));
    }

    async renderHome() {
      const [discovery, capabilities] = await Promise.all([
        this.request("/.well-known/ghpr-browser-bridge"),
        this.request("/api/v1/contracts/capabilities")
      ]);
      const d = this.document;
      const content = this.frame({
        active: "home",
        title: "Browser Bridge",
        eyebrow: "Local GitHub integration",
        actions: [
          element(d, "a", {
            className: "button primary",
            href: "/install/ghpr.user.js",
            text: "Install userscript"
          })
        ]
      });
      content.append(
        element(d, "section", { className: "connection-hero" }, [
          element(d, "span", { className: "connection-check", text: "✓", "aria-hidden": "true" }),
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: "Ready" }),
            element(d, "h2", { text: "Bring local PR tools into GitHub" }),
            element(d, "p", {
              text: `${discovery.protocol} · ghpr ${discovery.app_version} · 127.0.0.1 only`
            })
          ])
        ]),
        element(d, "div", { className: "diagnostic-grid" }, [
          this.diagnosticCard("Get started", [
            ["1", "Install ghpr for GitHub"],
            ["2", "Open a pull request"],
            ["3", "Approve the pairing request"]
          ]),
          this.diagnosticCard("Supported contracts", [
            ["Skill", capabilities.skill_contract.join(", ")],
            ["Presentation", capabilities.presentation_contract.join(", ")],
            ["Browser", capabilities.browser_contract.join(", ")],
            ["Slots", String(capabilities.supported_browser_slots.length)]
          ])
        ]),
        element(d, "section", { className: "panel" }, [
          element(d, "div", { className: "panel-heading" }, [
            element(d, "div", {}, [
              element(d, "div", { className: "eyebrow", text: "Local surfaces" }),
              element(d, "h3", { text: "Open privileged tools from the ghpr app" })
            ]),
            element(d, "span", { className: "visibility-pill", text: "Capability protected" })
          ]),
          element(d, "div", { className: "surface-list" }, [
            this.surfaceRow("CI analysis", "Evidence, relatedness, history, and recommendations"),
            this.surfaceRow("Skill runs", "Structured results, findings, artifacts, and execution state"),
            this.surfaceRow("Skill Workbench", "Create, validate, preview, and install local Skills"),
            this.surfaceRow("GitHub preview", "Inspect semantic slots without accessing GitHub")
          ])
        ])
      );
    }

    surfaceRow(title, description) {
      return element(this.document, "div", { className: "surface-row" }, [
        element(this.document, "span", { className: "surface-icon", text: "◈", "aria-hidden": "true" }),
        element(this.document, "div", {}, [
          element(this.document, "strong", { text: title }),
          element(this.document, "small", { text: description })
        ]),
        element(this.document, "span", { className: "chip", text: "Open from app" })
      ]);
    }

    async renderPairing() {
      this.stop();
      const parts = this.window.location.pathname.split("/").filter(Boolean);
      const pairingID = parts[parts.length - 1];
      const secret = new URLSearchParams(this.window.location.search).get("secret") || "";
      const status = await this.request(
        `/api/v1/pairings/${encodeURIComponent(pairingID)}/status?secret=${encodeURIComponent(secret)}`
      );
      const descriptor = status.descriptor;
      const required = new Set(descriptor.required_scopes || []);
      const scopes = [...(descriptor.requested_scopes || [])].sort();
      const missing = scopes.filter((scope) => required.has(scope) && !(status.client?.scopes || []).includes(scope));
      const content = this.frame({ active: "pairing", title: "Connect to ghpr", eyebrow: "Browser Integration" });
      const terminal = status.state === "denied" || status.state === "expired" ||
        (status.state === "approved" && missing.length > 0);
      const returnURL = this.safeGitHubReturnURL();
      const closeOrReturn = () => {
        this.window.close();
        this.pairingCloseTimer = this.window.setTimeout(() => {
          this.pairingCloseTimer = null;
          if (!this.window.closed && returnURL) this.window.location.replace(returnURL);
        }, 250);
      };
      const message = status.state === "pending"
        ? "Finish approval in the native ghpr window."
        : status.state === "approved" && missing.length === 0
          ? "Permissions updated"
          : status.state === "approved"
            ? `Missing permissions: ${missing.join(", ")}`
            : status.state === "denied" ? "Permission request denied." : "Permission request expired.";
      content.append(element(this.document, "section", { className: "pair-card", "aria-label": "Pair browser client" }, [
        appIcon(this.document, "pair-icon"),
        element(this.document, "div", { className: "eyebrow", text: status.state === "pending" ? "Waiting for approval" : "Pairing status" }),
        element(this.document, "h2", { text: message }),
        element(this.document, "p", { className: "lead", text: `Connect “${descriptor.name}” · ${descriptor.version}` }),
        element(this.document, "div", { className: "permission-list" }, scopes.map((scope) =>
          element(this.document, "div", { className: `permission ${required.has(scope) ? "elevated" : ""}` }, [
            element(this.document, "span", { text: required.has(scope) ? "!" : "✓" }),
            element(this.document, "div", {}, [
              element(this.document, "strong", { text: SCOPE_LABELS[scope] || titleCase(scope.replace(":", " ")) }),
              element(this.document, "small", { text: required.has(scope) ? "Required for this action" : scope })
            ])
          ])
        )),
        element(this.document, "div", { className: "native-callout" }, [
          element(this.document, "span", { className: "status-dot pulse" }),
          element(this.document, "p", { text: status.state === "pending" ? "Review permissions in the native ghpr window." : "You can return to the originating GitHub page." })
        ]),
        (status.state === "pending" ? null : element(this.document, "button", {
          className: "button primary",
          text: returnURL ? "Return now" : "Close this tab",
          onClick: closeOrReturn
        }))
      ]));
      if (status.state === "pending") {
        this.pairingStatusTimer = this.window.setTimeout(() => {
          this.renderPairing().catch((error) => this.renderFatal(error));
        }, 1000);
      } else if (status.state === "approved" && missing.length === 0) {
        this.pairingCloseTimer = this.window.setTimeout(() => {
          this.pairingCloseTimer = null;
          closeOrReturn();
        }, 1500);
      }
    }

    async renderAnalysis() {
      const analysisID = this.window.location.pathname.split("/").filter(Boolean).pop();
      const analysis = await this.request(
        `/api/v1/analyses/${encodeURIComponent(analysisID)}`
      );
      const d = this.document;
      const content = this.frame({
        active: "analysis",
        title: analysis.job_name || "CI Analysis",
        eyebrow: `${analysis.repository} · PR #${analysis.pr_number}`,
        actions: [
          element(d, "button", {
            className: "button secondary",
            text: "Copy signature",
            onClick: () => this.window.navigator.clipboard?.writeText(
              analysis.failure_signature || analysis.summary
            )
          }),
          element(d, "a", {
            className: "button primary",
            href: `https://github.com/${analysis.repository}/pull/${analysis.pr_number}`,
            text: "Back to pull request"
          })
        ]
      });
      const hero = element(d, "section", { className: `verdict-hero ${tone(analysis.verdict)}` }, [
        appIcon(d, "pulse-glyph"),
        element(d, "div", {}, [
          element(d, "div", { className: "eyebrow", text: "Verdict" }),
          element(d, "h2", { text: titleCase(analysis.verdict) }),
          element(d, "p", { text: analysis.summary })
        ]),
        element(d, "div", { className: "confidence" }, [
          element(d, "strong", { text: titleCase(analysis.confidence) }),
          element(d, "span", { text: `${percent(analysis.confidence_score)} confidence` })
        ])
      ]);
      const metrics = element(d, "section", { className: "metric-grid" }, [
        this.metric("History", `${analysis.history_matches.length} / ${analysis.history_checked}`, "matching runs"),
        this.metric("Relatedness", analysis.relatedness_score == null ? "—" : percent(analysis.relatedness_score), analysis.relatedness_summary || "Not available"),
        this.metric("Reproduction", analysis.reproduction, "Current run"),
        this.metric("Runtime", `${Math.round(analysis.duration_seconds)}s`, `${titleCase(analysis.agent)} · ${analysis.strict_context ? "Strict context" : "Standard context"}`)
      ]);
      const evidence = element(d, "section", { className: "panel wide" }, [
        element(d, "div", { className: "panel-heading" }, [
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: "Evidence" }),
            element(d, "h3", { text: "Historical signature matches" })
          ]),
          element(d, "span", { className: "chip", text: `${analysis.history_matches.length} matches` })
        ]),
        this.historyTable(analysis.history_matches)
      ]);
      const aside = element(d, "aside", { className: "analysis-aside" }, [
        this.detailCard("Failure signature", analysis.failure_signature || "No stable signature", "code"),
        this.detailCard("Recommended action", analysis.suggested_action, "action"),
        this.listCard("Changed files", analysis.changed_files)
      ]);
      content.append(hero, metrics, element(d, "div", { className: "analysis-layout" }, [evidence, aside]));
    }

    async renderRun() {
      this.stop();
      const runID = this.window.location.pathname.split("/").filter(Boolean).pop();
      const run = await this.request(`/api/v1/runs/${encodeURIComponent(runID)}`);
      const result = run.result || null;
      const d = this.document;
      const prNumber = run.page?.pr_number;
      const pullRequestURL = prNumber
        ? `https://github.com/${run.page.repository}/pull/${prNumber}`
        : null;
      const content = this.frame({
        active: "run",
        title: result?.title || run.skill_id,
        eyebrow: `${run.page?.repository || "Local Skill"}${prNumber ? ` · PR #${prNumber}` : ""}`,
        actions: pullRequestURL ? [
          element(d, "a", {
            className: "button primary",
            href: pullRequestURL,
            text: "Back to pull request"
          })
        ] : []
      });
      const statusDetail = result?.summary || run.progress_message || titleCase(run.status);
      const hero = element(d, "section", { className: `verdict-hero ${tone(run.status)}` }, [
        appIcon(d, "pulse-glyph"),
        element(d, "div", {}, [
          element(d, "div", { className: "eyebrow", text: "Skill run" }),
          element(d, "h2", { text: titleCase(run.status) }),
          element(d, "p", { text: statusDetail })
        ])
      ]);
      const startedAt = run.started_at ? new Date(run.started_at) : null;
      const completedAt = run.completed_at ? new Date(run.completed_at) : null;
      const durationEnd = completedAt || (startedAt ? new Date() : null);
      const duration = startedAt && durationEnd
        ? `${Math.max(0, Math.round((durationEnd - startedAt) / 1000))}s`
        : "—";
      const metrics = element(d, "section", { className: "metric-grid" }, [
        this.metric("Status", titleCase(run.status), run.progress_message || "Latest state"),
        this.metric("Skill", run.skill_id, run.retry_of_run_id ? "Retry" : "Original run"),
        this.metric("Duration", duration, run.completed_at ? "Completed" : "In progress")
      ]);
      const logPanel = this.runLog(run);
      const output = element(d, "section", { className: "panel wide" }, [
        element(d, "div", { className: "panel-heading" }, [
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: "Structured result" }),
            element(d, "h2", { text: "Output" })
          ])
        ])
      ]);
      if (result?.code_review) {
        output.append(element(d, "p", { text: result.code_review.overview_markdown }));
        for (const finding of result.code_review.findings || []) {
          output.append(element(d, "article", { className: "detail-card" }, [
            element(d, "strong", {
              text: `${finding.file}${finding.line ? `:${finding.line}` : ""} · ${titleCase(finding.severity)}`
            }),
            element(d, "p", { text: finding.body })
          ]));
        }
      } else if (result?.analysis) {
        output.append(
          element(d, "h3", { text: titleCase(result.analysis.verdict) }),
          element(d, "p", { text: result.analysis.summary })
        );
      } else if (result?.markdown) {
        output.append(element(d, "pre", { className: "code-block", text: result.markdown }));
      } else {
        output.append(element(d, "p", { text: statusDetail }));
      }
      const artifacts = result?.artifacts || [];
      const artifactPanel = element(d, "aside", { className: "analysis-aside" }, [
        this.listCard(
          "Artifacts",
          artifacts.map((artifact) =>
            `${artifact.name} · ${artifact.media_type}${artifact.relative_path ? ` · ${artifact.relative_path}` : ""}`
          )
        )
      ]);
      content.append(
        hero,
        metrics,
        logPanel,
        element(d, "div", { className: "analysis-layout" }, [output, artifactPanel])
      );
      if (run.status === "queued" || run.status === "running") {
        this.scheduleRunRefresh();
      }
    }

    runLog(run) {
      const d = this.document;
      const isLive = run.status === "queued" || run.status === "running";
      const steps = this.runStepGroups(run);
      return element(d, "section", {
        className: "panel wide run-log-panel",
        "aria-label": "Skill execution log"
      }, [
        element(d, "div", { className: "panel-heading" }, [
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: "Execution" }),
            element(d, "h2", { text: "Steps" })
          ]),
          element(d, "span", {
            className: `chip ${isLive ? "warning" : tone(run.status)}`,
            text: isLive ? "Live · refreshes every 2s" : titleCase(run.status)
          })
        ]),
        element(d, "div", {
          className: "run-steps",
          role: "log",
          "aria-live": isLive ? "polite" : "off"
        }, steps.map((step) => this.runStep(step)))
      ]);
    }

    runLogEntries(run) {
      if (Array.isArray(run.log_entries) && run.log_entries.length) return run.log_entries;
      return [{
        timestamp: run.created_at,
        kind: run.status === "failed" ? "error" : "running",
        message: run.progress_message || titleCase(run.status)
      }];
    }

    runStepGroups(run) {
      const groups = RUN_STEPS.map((step) => ({ ...step, entries: [] }));
      const terminalKinds = ["success", "warning", "error"];
      let cursor = 0;
      for (const entry of this.runLogEntries(run)) {
        let index = groups.findIndex((group) => group.messages.includes(entry.message));
        if (index === -1 && terminalKinds.includes(entry.kind)) index = groups.length - 1;
        if (index === -1) {
          index = cursor;
        } else {
          cursor = Math.max(cursor, index);
        }
        groups[index].entries.push(entry);
      }
      const reached = groups.filter((group) => group.entries.length);
      const isLive = run.status === "queued" || run.status === "running";
      return reached.map((group, index) => {
        const next = reached[index + 1];
        const endValue = next ? next.entries[0].timestamp : run.completed_at;
        const failed = group.entries.some((entry) => entry.kind === "error");
        const cancelled = !failed && group.entries.some((entry) => entry.kind === "warning");
        const running = !failed && !cancelled && isLive && index === reached.length - 1;
        return {
          id: group.id,
          name: group.name,
          entries: group.entries,
          status: failed ? "failed" : cancelled ? "cancelled" : running ? "running" : "success",
          duration: this.stepDuration(
            group.entries[0].timestamp,
            endValue || (isLive ? new Date().toISOString() : null)
          )
        };
      });
    }

    stepDuration(startValue, endValue) {
      if (!startValue || !endValue) return "—";
      const startedAt = new Date(startValue);
      const endedAt = new Date(endValue);
      if (Number.isNaN(startedAt.getTime()) || Number.isNaN(endedAt.getTime())) return "—";
      return `${Math.max(0, Math.round((endedAt - startedAt) / 1000))}s`;
    }

    isRunStepOpen(step) {
      if (this.runStepState.has(step.id)) return this.runStepState.get(step.id);
      return step.status === "running" || step.status === "failed";
    }

    runStep(step) {
      const d = this.document;
      const count = `${step.entries.length} ${step.entries.length === 1 ? "event" : "events"}`;
      const details = element(d, "details", {
        className: `run-step ${step.status}`,
        dataset: { step: step.id }
      }, [
        element(d, "summary", {}, [
          element(d, "span", {
            className: "run-step-marker",
            text: STEP_MARKERS[step.status] || "·",
            "aria-hidden": "true"
          }),
          element(d, "span", { className: "run-step-name", text: step.name }),
          element(d, "span", { className: "run-step-meta", text: `${count} · ${step.duration}` })
        ]),
        element(
          d,
          "div",
          { className: "run-log" },
          step.entries.map((entry) => this.runLogLine(entry))
        )
      ]);
      details.open = this.isRunStepOpen(step);
      details.addEventListener("toggle", () => {
        this.runStepState.set(step.id, details.open);
      });
      return details;
    }

    runLogLine(entry) {
      const d = this.document;
      const timestamp = new Date(entry.timestamp);
      const time = Number.isNaN(timestamp.getTime())
        ? "—"
        : timestamp.toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
            second: "2-digit",
            hour12: false
          });
      return element(d, "div", {
        className: `run-log-line ${entry.kind || "running"}`
      }, [
        element(d, "time", { text: time }),
        element(d, "span", {
          className: "run-log-marker",
          text: LOG_MARKERS[entry.kind] || "·",
          "aria-hidden": "true"
        }),
        element(d, "code", { text: entry.message })
      ]);
    }

    metric(label, value, detail) {
      return element(this.document, "article", { className: "metric" }, [
        element(this.document, "span", { text: label }),
        element(this.document, "strong", { text: value }),
        element(this.document, "small", { text: detail })
      ]);
    }

    historyTable(rows) {
      const d = this.document;
      if (!rows.length) {
        return element(d, "div", { className: "empty-row", text: "No historical match was found." });
      }
      const body = element(d, "tbody", {}, rows.map((row) => element(d, "tr", {}, [
        element(d, "td", { text: row.run_number ? `#${row.run_number}` : "—" }),
        element(d, "td", { text: row.branch }),
        element(d, "td", { text: new Date(row.date).toLocaleDateString() }),
        element(d, "td", {}, [element(d, "span", { className: "score", text: percent(row.similarity) })]),
        element(d, "td", {}, [element(d, "span", { className: `result ${row.result}`, text: titleCase(row.result) })])
      ])));
      return element(d, "div", { className: "table-scroll" }, [
        element(d, "table", {}, [
          element(d, "thead", {}, [element(d, "tr", {}, ["Run", "Branch", "Date", "Similarity", "Result"].map(
            (label) => element(d, "th", { text: label })
          ))]),
          body
        ])
      ]);
    }

    detailCard(title, value, kind) {
      return element(this.document, "section", { className: `detail-card ${kind}` }, [
        element(this.document, "span", { text: title }),
        element(this.document, "strong", { text: value })
      ]);
    }

    listCard(title, values) {
      return element(this.document, "section", { className: "detail-card" }, [
        element(this.document, "span", { text: title }),
        ...(values?.length
          ? values.map((value) => element(this.document, "code", { text: value }))
          : [element(this.document, "small", { text: "None" })])
      ]);
    }

    async renderWorkbenchStart() {
      this.workbench.capabilities = await this.request("/api/v1/contracts/capabilities");
      this.renderWorkbench();
    }

    renderWorkbench() {
      const d = this.document;
      const state = this.workbench;
      const frameActions = [
        element(d, "button", {
          className: "button secondary",
          text: "Install Skill Builder",
          disabled: state.busy,
          onClick: () => this.workbenchOperation("install_builder", {
            agents: ["claude_code", "codex", "omp"]
          })
        }),
        element(d, "a", {
          className: "button secondary",
          href: `/ui/github-preview?cap=${encodeURIComponent(this.capability)}`,
          text: "Open GitHub Preview"
        })
      ];
      if (state.installed) {
        frameActions.push(element(d, "button", {
          className: "button secondary",
          text: "Create another Skill",
          onClick: () => {
            this.workbench = { ...this.workbench, stage: 0, packagePath: null, files: {}, preview: null, validation: null, fixturePassed: false, permissionsReviewed: false, mode: "create", error: null, notice: null, installed: false };
            this.renderWorkbench();
          }
        }));
      }
      const content = this.frame({
        active: "workbench",
        title: "Skill Workbench",
        eyebrow: "Build against the installed contract",
        actions: frameActions
      });
      content.append(this.stageBar());
      if (state.error) {
        content.append(element(d, "div", { className: "banner error", text: state.error }));
      } else if (state.notice) {
        content.append(element(d, "div", { className: "banner success", text: state.notice }));
      }
      if (!state.packagePath) {
        content.append(this.workbenchWelcome());
        return;
      }
      const layout = element(d, "div", { className: "workbench-layout" }, [
        this.workbenchEditor(),
        this.workbenchPreview()
      ]);
      content.append(layout, this.workbenchFooter());
    }

    stageBar() {
      const d = this.document;
      return element(d, "ol", { className: "stage-bar", "aria-label": "Skill workflow" },
        STAGES.map(([label, detail], index) => {
          const selectable = this.canSelectStage(index);
          const classNames = [
            index === this.workbench.stage ? "active" : "",
            index < this.workbench.stage ? "complete" : "",
            selectable ? "" : "locked"
          ].filter(Boolean).join(" ");
          return element(d, "li", {
            className: classNames,
            onClick: () => this.selectStage(index)
          }, [
            element(d, "button", { type: "button", disabled: !selectable }, [
              element(d, "span", { className: "stage-number", text: index < this.workbench.stage ? "✓" : String(index + 1) }),
              element(d, "span", {}, [
                element(d, "strong", { text: label }),
                element(d, "small", { text: detail })
              ])
            ])
          ]);
        })
      );
    }

    canSelectStage(index) {
      const state = this.workbench;
      if (!state.packagePath) return index === 0;
      if (index <= 1) return true;
      if (index === 2) return state.validation?.valid === true;
      if (index === 3) return state.fixturePassed;
      if (index === 4) return state.fixturePassed && state.preview != null;
      return state.fixturePassed &&
        state.permissionsReviewed &&
        state.validation?.valid === true;
    }

    async selectStage(index) {
      if (!this.workbench.packagePath || this.workbench.busy) return;
      if (!this.canSelectStage(index)) {
        this.workbench.error = index === 5
          ? "Run the fixture and approve the permission review before installation."
          : "Complete the preceding verification stage first.";
        this.renderWorkbench();
        return;
      }
      this.workbench.stage = index;
      if (index === 1) await this.workbenchOperation("validate");
      else if (index === 2) await this.workbenchOperation("test");
      else if (index === 3 || index === 4) await this.workbenchOperation("preview");
      else if (index === 5) {
        if (this.window.confirm("Install this verified Skill for ghpr?")) {
          await this.workbenchOperation("install");
        } else {
          this.renderWorkbench();
        }
      } else {
        this.renderWorkbench();
      }
    }

    async discoverAgentSkills() {
      const state = this.workbench;
      state.discoveryBusy = true;
      state.discoveryError = null;
      this.renderWorkbench();
      try {
        const payload = await this.request("/api/v1/workbench", {
          method: "POST",
          body: JSON.stringify({ operation: "discover_skills" })
        });
        state.discoveredSkills = Array.isArray(payload.skills) ? payload.skills : [];
        state.discoveryLoaded = true;
      } catch (error) {
        state.discoveryError = error.message || String(error);
      } finally {
        state.discoveryBusy = false;
        this.renderWorkbench();
      }
    }

    workbenchSkillSource({ manualLabel, placeholder }) {
      const d = this.document;
      const state = this.workbench;
      const skills = state.discoveredSkills;
      const elements = [];
      let discoveredSelect = null;

      if (state.discoveryBusy) {
        elements.push(element(d, "div", {
          className: "discovery-note",
          text: "Looking in Claude Code, Codex, and OMP…"
        }));
      } else if (state.discoveryError) {
        elements.push(element(d, "div", {
          className: "discovery-note warning",
          text: `Automatic discovery failed: ${state.discoveryError}`
        }));
      } else if (state.discoveryLoaded && skills.length > 0) {
        discoveredSelect = element(d, "select", {
          name: "discovered_skill_path",
          className: "discovered-skill-select"
        }, [
          element(d, "option", { value: "", text: "Choose a discovered Skill" }),
          ...skills.map((skill) => element(d, "option", {
            value: skill.path,
            text: `${skill.display_name} — ${skill.agents.map((agent) =>
              agent === "omp" ? "OMP" : titleCase(agent)
            ).join(" + ")}`
          }))
        ]);
        elements.push(
          element(d, "label", {}, [
            element(d, "span", { text: "Discovered agent Skill" }),
            discoveredSelect
          ]),
          element(d, "div", {
            className: "discovery-note",
            text: `Found ${skills.length} compatible Skill${skills.length === 1 ? "" : "s"} in Claude Code, Codex, and OMP.`
          })
        );
      } else if (state.discoveryLoaded) {
        elements.push(element(d, "div", {
          className: "discovery-note",
          text: "No agent Skills were found in Claude Code, Codex, or OMP. Enter a path below."
        }));
      }

      const manualPath = element(d, "input", {
        name: "manual_skill_path",
        placeholder,
        autocomplete: "off"
      });
      elements.push(element(d, "label", {}, [
        element(d, "span", { text: manualLabel }),
        manualPath
      ]));
      return {
        elements,
        value: () => manualPath.value.trim() || discoveredSelect?.value.trim() || ""
      };
    }

    workbenchWelcome() {
      const d = this.document;
      const state = this.workbench;
      const submitAndPreview = async (operation, payload) => {
        await this.workbenchOperation(operation, payload);
        if (state.packagePath) await this.workbenchOperation("preview");
      };
      const modeSwitch = element(d, "div", {
        className: "mode-switch",
        role: "tablist",
        "aria-label": "Skill Builder mode"
      }, [
        ["create", "Create"],
        ["migrate", "Migrate"],
        ["enhance", "Enhance"]
      ].map(([mode, label]) => element(d, "button", {
        type: "button",
        role: "tab",
        className: state.mode === mode ? "active" : "",
        dataset: { mode },
        "aria-selected": state.mode === mode ? "true" : "false",
        text: label,
        onClick: async () => {
          state.mode = mode;
          state.error = null;
          this.renderWorkbench();
          if (mode !== "create" && !state.discoveryLoaded && !state.discoveryBusy) {
            await this.discoverAgentSkills();
          }
        }
      })));

      let modeForm;
      if (state.mode === "migrate") {
        const source = this.workbenchSkillSource({
          manualLabel: "Or enter a source Skill path",
          placeholder: "~/.codex/skills/flaky-investigator"
        });
        const id = element(d, "input", {
          name: "id",
          required: "required",
          value: "user.migrated-skill",
          autocomplete: "off"
        });
        modeForm = element(d, "form", {
          className: "create-form migrate-form",
          onSubmit: async (event) => {
            event.preventDefault();
            const sourcePath = source.value();
            if (!sourcePath) {
              state.error = "Choose a discovered Skill or enter its path.";
              this.renderWorkbench();
              return;
            }
            await submitAndPreview("migrate", {
              source_path: sourcePath,
              id: id.value.trim()
            });
          }
        }, [
          element(d, "div", { className: "eyebrow", text: "Migrate" }),
          element(d, "h2", { text: "Preserve an existing agent Skill" }),
          element(d, "p", {
            text: "Keep the source unchanged, create a ghpr-managed copy, and add a Level 0 result contract."
          }),
          ...source.elements,
          element(d, "label", {}, [element(d, "span", { text: "New ghpr Skill ID" }), id]),
          element(d, "button", {
            className: "button primary",
            type: "submit",
            text: state.busy ? "Migrating…" : "Migrate Skill",
            disabled: state.busy
          })
        ]);
      } else if (state.mode === "enhance") {
        const source = this.workbenchSkillSource({
          manualLabel: "Or enter a Skill path",
          placeholder: "/path/to/existing-skill"
        });
        const slot = element(d, "select", {
          name: "slot",
          "aria-label": "GitHub semantic slot"
        }, Object.entries(SLOT_LABELS).map(([value, label]) =>
          element(d, "option", { value, text: label })
        ));
        modeForm = element(d, "form", {
          className: "create-form enhance-form",
          onSubmit: async (event) => {
            event.preventDefault();
            const packagePath = source.value();
            if (!packagePath) {
              state.error = "Choose a discovered Skill or enter its path.";
              this.renderWorkbench();
              return;
            }
            await submitAndPreview("enhance", {
              package_path: packagePath,
              slot: slot.value
            });
          }
        }, [
          element(d, "div", { className: "eyebrow", text: "Enhance" }),
          element(d, "h2", { text: "Add presentation and GitHub surfaces" }),
          element(d, "p", {
            text: "Work on a managed copy. Execution instructions and result semantics remain unchanged."
          }),
          ...source.elements,
          element(d, "label", {}, [element(d, "span", { text: "GitHub placement" }), slot]),
          element(d, "button", {
            className: "button primary",
            type: "submit",
            text: state.busy ? "Preparing…" : "Enhance Skill",
            disabled: state.busy
          })
        ]);
      } else {
        const id = element(d, "input", {
          name: "id",
          required: "required",
          value: "team.ci.policy-check",
          autocomplete: "off"
        });
        const name = element(d, "input", {
          name: "display_name",
          required: "required",
          value: "Team CI Policy Check",
          autocomplete: "off"
        });
        modeForm = element(d, "form", {
          className: "create-form",
          onSubmit: async (event) => {
            event.preventDefault();
            await submitAndPreview("scaffold", {
              id: id.value.trim(),
              display_name: name.value.trim()
            });
          }
        }, [
          element(d, "div", { className: "eyebrow", text: "Create" }),
          element(d, "h2", { text: "Start with a safe contract" }),
          element(d, "p", {
            text: "Scaffold a strict, read-only, manually triggered Skill with schema and browser fixtures."
          }),
          element(d, "label", {}, [element(d, "span", { text: "Skill ID" }), id]),
          element(d, "label", {}, [element(d, "span", { text: "Display name" }), name]),
          element(d, "button", {
            className: "button primary",
            type: "submit",
            text: state.busy ? "Creating…" : "Create Skill",
            disabled: state.busy
          })
        ]);
      }

      const checklist = element(d, "section", { className: "contract-card" }, [
        element(d, "div", { className: "eyebrow", text: "Current ghpr contract" }),
        element(d, "h2", { text: "Capabilities detected" }),
        ...[
          ["Skill", state.capabilities?.skill_contract?.join(", ")],
          ["Presentation", state.capabilities?.presentation_contract?.join(", ")],
          ["Browser", state.capabilities?.browser_contract?.join(", ")],
          ["Agents", state.capabilities?.supported_agents?.join(", ")]
        ].map(([label, value]) => element(d, "div", { className: "contract-row" }, [
          element(d, "span", { text: "✓" }),
          element(d, "strong", { text: label }),
          element(d, "small", { text: value || "Unavailable" })
        ])),
        element(d, "p", {
          className: "muted",
          text: `${state.capabilities?.supported_browser_slots?.length || 0} semantic Browser slots available`
        })
      ]);
      return element(d, "div", { className: "welcome-shell" }, [
        modeSwitch,
        element(d, "div", { className: "welcome-grid" }, [modeForm, checklist])
      ]);
    }

    workbenchEditor() {
      const d = this.document;
      const state = this.workbench;
      const available = EDITABLE_FILES.filter(([path]) => path !== "browser/contributions.yaml" || state.files[path] != null);
      if (!available.some(([path]) => path === state.activeFile)) {
        state.activeFile = available[0][0];
      }
      const tabs = element(d, "div", { className: "editor-tabs" }, available.map(([path, label]) =>
        element(d, "button", {
          type: "button",
          className: path === state.activeFile ? "active" : "",
          text: label,
          onClick: () => {
            state.activeFile = path;
            this.renderWorkbench();
          }
        })
      ));
      const editor = element(d, "textarea", {
        className: "code-editor",
        spellcheck: "false",
        "aria-label": `Edit ${state.activeFile}`,
        value: state.files[state.activeFile] || "",
        onInput: (event) => {
          state.files[state.activeFile] = event.target.value;
        }
      });
      const issues = state.validation?.issues || [];
      return element(d, "section", { className: "editor-panel" }, [
        element(d, "div", { className: "editor-heading" }, [
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: "Contract source" }),
            element(d, "h2", { text: state.preview?.display_name || "Skill package" })
          ]),
          element(d, "button", {
            className: "button primary compact",
            text: state.busy ? "Saving…" : "Save",
            disabled: state.busy,
            onClick: () => this.workbenchOperation("save", { files: state.files })
          })
        ]),
        tabs,
        editor,
        element(d, "div", { className: "issue-list" },
          issues.length
            ? issues.map((issue) => element(d, "div", { className: `issue ${issue.severity}` }, [
              element(d, "strong", { text: issue.severity === "error" ? "!" : "△" }),
              element(d, "span", { text: `${issue.path}: ${issue.message}` })
            ]))
            : [element(d, "div", { className: "issue valid", text: "✓ Contract structure is valid" })]
        )
      ]);
    }

    workbenchPreview() {
      const d = this.document;
      const state = this.workbench;
      const preview = state.preview;
      if (!preview) {
        return element(d, "section", { className: "preview-panel empty-preview" }, [
          appIcon(d, "large-icon"),
          element(d, "h2", { text: "Preview unavailable" }),
          element(d, "p", { text: "Save a valid package to render its native and GitHub surfaces." })
        ]);
      }
      const result = this.parseJSON(preview.expected_result);
      const status = result?.status || "needs_investigation";
      const summary = result?.summary || result?.output || "Fixture output will appear here.";
      const permissions = preview.requested_capabilities || [];
      const slot = this.extractSlot(preview.browser_contributions);
      const previewBody = state.stage === 4
        ? element(d, "div", { className: "permission-review" }, [
          element(d, "div", { className: "eyebrow", text: "Permission diff" }),
          element(d, "h3", { text: permissions.length ? "Additional capabilities requested" : "Safe defaults retained" }),
          ...(permissions.length
            ? permissions.map((permission) => element(d, "div", { className: "permission elevated" }, [
              element(d, "span", { text: "+" }),
              element(d, "strong", { text: permission })
            ]))
            : [
              this.safeDefault("Strict isolation"),
              this.safeDefault("Read-only workspace"),
              this.safeDefault("Shell denied"),
              this.safeDefault("Network denied"),
              this.safeDefault("Manual execution")
            ]),
          element(d, "button", {
            className: state.permissionsReviewed ? "button secondary" : "button primary",
            text: state.permissionsReviewed ? "Permissions reviewed ✓" : "Approve permission review",
            disabled: state.permissionsReviewed,
            onClick: () => {
              state.permissionsReviewed = true;
              state.notice = "Permission review approved. Installation is now available.";
              this.renderWorkbench();
            }
          })
        ])
        : element(d, "div", {}, [
          element(d, "div", { className: `mini-verdict ${tone(status)}` }, [
            appIcon(d, "pulse-glyph"),
            element(d, "div", {}, [
              element(d, "small", { text: "ghpr Skill result" }),
              element(d, "strong", { text: titleCase(status) }),
              element(d, "p", { text: summary })
            ])
          ]),
          element(d, "div", { className: "github-surface" }, [
            element(d, "div", { className: "github-topline" }, [
              element(d, "span", { text: "GitHub PR" }),
              element(d, "code", { text: slot || "pr.header.actions" })
            ]),
            element(d, "div", { className: "github-card" }, [
              element(d, "strong", { text: preview.display_name }),
              element(d, "span", { className: `chip ${tone(status)}`, text: titleCase(status) }),
              element(d, "p", { text: summary }),
              element(d, "button", { type: "button", text: "Open Full Analysis" })
            ])
          ])
        ]);
      return element(d, "section", { className: "preview-panel" }, [
        element(d, "div", { className: "preview-heading" }, [
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: state.stage === 4 ? "Security review" : "Live preview" }),
            element(d, "h2", { text: preview.display_name })
          ]),
          element(d, "span", { className: "version-pill", text: `v${preview.version}` })
        ]),
        previewBody,
        element(d, "div", { className: "slot-note" }, [
          element(d, "span", { className: "status-dot" }),
          element(d, "span", { text: SLOT_LABELS[slot] || "Header fallback available" })
        ])
      ]);
    }

    safeDefault(label) {
      return element(this.document, "div", { className: "permission safe" }, [
        element(this.document, "span", { text: "✓" }),
        element(this.document, "strong", { text: label })
      ]);
    }

    workbenchFooter() {
      const d = this.document;
      return element(d, "div", { className: "workbench-footer" }, [
        element(d, "div", { className: "workflow-status" }, [
          element(d, "span", { className: this.workbench.validation?.valid ? "status-dot" : "status-dot warning" }),
          element(d, "span", {
            text: this.workbench.validation?.valid
              ? "Contract ready"
              : "Resolve contract errors before installation"
          })
        ]),
        element(d, "div", { className: "button-row" }, [
          element(d, "button", {
            className: "button secondary",
            text: "Pack",
            disabled: this.workbench.busy || !this.workbench.fixturePassed,
            onClick: () => this.workbenchOperation("pack")
          }),
          element(d, "button", {
            className: "button secondary",
            text: "Run Fixture",
            disabled: this.workbench.busy || !this.workbench.validation?.valid,
            onClick: () => {
              this.workbench.stage = 2;
              this.workbenchOperation("test");
            }
          }),
          element(d, "button", {
            className: "button primary",
            text: "Review & Install",
            disabled: this.workbench.busy || !this.workbench.fixturePassed,
            onClick: () => {
              this.workbench.stage = 4;
              this.workbenchOperation("preview");
            }
          })
        ])
      ]);
    }

    async workbenchOperation(operation, extra = {}) {
      const state = this.workbench;
      state.busy = true;
      state.error = null;
      state.notice = null;
      if (["scaffold", "save", "enhance"].includes(operation)) {
        state.fixturePassed = false;
        state.permissionsReviewed = false;
      }
      this.renderWorkbench();
      try {
        const payload = await this.request("/api/v1/workbench", {
          method: "POST",
          body: JSON.stringify({
            operation,
            package_path: state.packagePath,
            ...extra
          })
        });
        if (payload.path && operation !== "pack" && operation !== "install") {
          state.packagePath = payload.path;
        }
        if (payload.validation) state.validation = payload.validation;
        if (payload.preview) {
          state.preview = payload.preview;
          state.files = {
            "ghpr.skill.yaml": payload.preview.manifest,
            "schemas/result.schema.json": payload.preview.result_schema,
            "presentation/presentation.yaml": payload.preview.presentation,
            "fixtures/expected-result.json": payload.preview.expected_result || ""
          };
          if (payload.preview.browser_contributions != null) {
            state.files["browser/contributions.yaml"] = payload.preview.browser_contributions;
          }
        }
        if (payload.install_statuses) {
          state.notice = `Skill Builder installed for ${payload.install_statuses.map(
            (status) => titleCase(status.agent)
          ).join(", ")}.`;
        } else if (operation === "test") {
          state.fixturePassed = true;
          state.permissionsReviewed = false;
          state.notice = "Fixture matches the declared result schema.";
        } else if (operation === "pack") {
          state.notice = "Signed-off package artifact created in the Workbench drafts folder.";
        } else if (operation === "install") {
          state.installed = true;
        } else if (operation === "save") {
          state.notice = state.validation?.valid ? "Saved and validated." : "Saved with contract issues.";
        }
      } catch (error) {
        state.error = error.message || String(error);
      } finally {
        state.busy = false;
        this.renderWorkbench();
      }
    }

    parseJSON(value) {
      try {
        return value ? JSON.parse(value) : null;
      } catch {
        return null;
      }
    }

    extractSlot(source) {
      return Object.keys(SLOT_LABELS).find((slot) => String(source || "").includes(slot)) || null;
    }

    renderGitHubPreview() {
      const d = this.document;
      const content = this.frame({
        active: "github-preview",
        title: "GitHub PR Integration Preview",
        eyebrow: "Static fixture · no GitHub access",
        actions: [
          element(d, "a", {
            className: "button secondary",
            href: `/ui/workbench?cap=${encodeURIComponent(this.capability)}`,
            text: "Back to Skill Workbench"
          })
        ]
      });
      const mock = element(d, "section", { className: "github-mock" }, [
        element(d, "div", { className: "mock-browser-bar" }, [
          element(d, "span", { text: "● ● ●" }),
          element(d, "code", { text: "github.com/example-org/service/pull/1238" })
        ]),
        element(d, "div", { className: "mock-repo-nav", text: "example-org / service   Code   Pull requests   Actions" }),
        element(d, "div", { className: "mock-pr-header" }, [
          element(d, "div", {}, [
            element(d, "h2", { text: "Make CI history comparison deterministic #1238" }),
            element(d, "p", { text: "Open · xiaocang wants to merge 2 commits into main" })
          ]),
          element(d, "button", { className: "ghpr-mock-button" }, [
            appIcon(d, "ghpr-inline-icon"),
            "ghpr ▾"
          ])
        ]),
        element(d, "div", { className: "mock-columns" }, [
          element(d, "div", { className: "mock-conversation" }, [
            element(d, "div", { className: "mock-check-row" }, [
              element(d, "div", {}, [
                element(d, "strong", { text: "unit-test" }),
                element(d, "small", { text: "Failed in 4m 12s" })
              ]),
              element(d, "div", {}, [
                element(d, "span", { className: "chip warning", text: "Likely flaky" }),
                element(d, "button", { text: "Analyze ▾" })
              ])
            ]),
            element(d, "article", { className: "github-card large" }, [
              element(d, "div", { className: "github-card-title" }, [
                element(d, "span", { className: "mock-ghpr-title" }, [
                  appIcon(d, "ghpr-inline-icon"),
                  element(d, "strong", { text: "ghpr CI Analysis" })
                ]),
                element(d, "span", { className: "chip warning", text: "High confidence" })
              ]),
              element(d, "h3", { text: "Likely flaky" }),
              element(d, "p", { text: "The same signature appeared in 3 main-branch runs." }),
              element(d, "div", { className: "mock-metrics" }, [
                this.metric("History", "3 / 20", "matches"),
                this.metric("Relatedness", "12%", "low"),
                this.metric("Reproduction", "Not rerun", "current run")
              ]),
              element(d, "div", { className: "button-row" }, [
                element(d, "button", { text: "Rerun" }),
                element(d, "button", { text: "Mark Flaky" }),
                element(d, "button", { className: "primary", text: "Full Analysis" })
              ])
            ])
          ]),
          element(d, "aside", { className: "mock-mergebox" }, [
            element(d, "strong", { text: "Checks have failed" }),
            element(d, "p", { text: "1 failing check" }),
            element(d, "button", { disabled: true, text: "Merge pull request" })
          ])
        ])
      ]);
      content.append(
        element(d, "div", { className: "preview-legend" }, [
          element(d, "span", { text: "Semantic slots" }),
          ...["pr.header.actions", "checks.run.trailing", "pr.conversation.after-checks"].map(
            (slot) => element(d, "code", { text: slot })
          )
        ]),
        mock
      );
    }

    async renderBrowserTest() {
      const [discovery, capabilities] = await Promise.all([
        this.request("/.well-known/ghpr-browser-bridge"),
        this.request("/api/v1/contracts/capabilities")
      ]);
      const d = this.document;
      const content = this.frame({
        active: "browser-test",
        title: "Browser Integration Test",
        eyebrow: "Loopback diagnostics",
        actions: [
          element(d, "a", {
            className: "button secondary",
            href: `/ui/workbench?cap=${encodeURIComponent(this.capability)}`,
            text: "Back to Skill Workbench"
          })
        ]
      });
      content.append(
        element(d, "section", { className: "connection-hero" }, [
          element(d, "span", { className: "connection-check", text: "✓" }),
          element(d, "div", {}, [
            element(d, "div", { className: "eyebrow", text: "Connected" }),
            element(d, "h2", { text: "Browser Bridge is reachable" }),
            element(d, "p", {
              text: `${discovery.protocol} · ghpr ${discovery.app_version}`
            })
          ])
        ]),
        element(d, "div", { className: "diagnostic-grid" }, [
          this.diagnosticCard("Network boundary", [
            ["Listener", "127.0.0.1 only"],
            ["Authentication", "Bearer capabilities"],
            ["Cookies", "Disabled"],
            ["CORS", "Exact loopback origin"]
          ]),
          this.diagnosticCard("Contracts", [
            ["Skill", capabilities.skill_contract.join(", ")],
            ["Presentation", capabilities.presentation_contract.join(", ")],
            ["Browser", capabilities.browser_contract.join(", ")],
            ["Slots", String(capabilities.supported_browser_slots.length)]
          ])
        ]),
        element(d, "section", { className: "panel" }, [
          element(d, "div", { className: "panel-heading" }, [
            element(d, "div", {}, [
              element(d, "div", { className: "eyebrow", text: "Data isolation" }),
              element(d, "h3", { text: "Never exposed to browser clients" })
            ])
          ]),
          element(d, "div", { className: "denied-grid" },
            ["GitHub token", "Workspace path", "Agent credentials", "Raw repository read", "Shell execution"].map(
              (label) => element(d, "div", {}, [
                element(d, "span", { text: "×" }),
                element(d, "strong", { text: label })
              ])
            )
          )
        ])
      );
    }

    diagnosticCard(title, rows) {
      return element(this.document, "section", { className: "diagnostic-card" }, [
        element(this.document, "h3", { text: title }),
        ...rows.map(([label, value]) => element(this.document, "div", {}, [
          element(this.document, "span", { text: label }),
          element(this.document, "strong", { text: value })
        ]))
      ]);
    }
  }

  const exported = {
    LocalApp,
    createLocalApp: (options) => new LocalApp(options),
    EDITABLE_FILES,
    STAGES
  };

  if (global.__GHPR_LOCAL_TEST__) {
    global.GhprLocalUI = exported;
  } else {
    const app = new LocalApp({
      window: global,
      document: global.document,
      fetch: global.fetch.bind(global)
    });
    app.start();
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
