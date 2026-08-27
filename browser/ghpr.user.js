// ==UserScript==
// @name         ghpr for GitHub
// @namespace    https://github.com/xiaocang/ghpr-view
// @version      1.2.0
// @description  Run local ghpr Skills and render their results on GitHub pull requests.
// @match        https://github.com/*/*/pull/*
// @match        https://github.com/*/*/actions/runs/*
// @grant        GM.xmlHttpRequest
// @grant        GM.openInTab
// @grant        GM.registerMenuCommand
// @grant        GM.getValue
// @grant        GM.setValue
// @connect      localhost
// @connect      127.0.0.1
// @run-at       document-idle
// ==/UserScript==

(function ghprUserscriptModule(global) {
  "use strict";

  const CLIENT = {
    id: "dev.ghpr.official-userscript",
    name: "ghpr for GitHub",
    version: "1.2.0",
    requested_scopes: [
      "pr:read",
      "ci:read",
      "analysis:read",
      "skill:list",
      "skill:run",
      "skill:cancel",
      "tag:read",
      "tag:write",
      "ui:contribute",
      "detail:open",
      "app:open"
    ]
  };
  const DISCOVERY_PORTS = Array.from({ length: 10 }, (_, index) => 48120 + index);
  const STORAGE = {
    port: "ghpr.bridge.port",
    instance: "ghpr.bridge.instance",
    token: "ghpr.bridge.token"
  };
  const PERMISSION_LABELS = {
    "skill:run": "Run configured Skills",
    "skill:cancel": "Cancel Skill runs",
    "tag:write": "Change locally stored ghpr tags",
    "detail:open": "Open local analysis",
    "app:open": "Open ghpr-view"
  };
  const ROOT_ID = "ghpr-github-root";
  const STYLE_ID = "ghpr-github-styles";
  const MANAGED_ATTRIBUTE = "data-ghpr-managed";
  const POLL_ACTIVE_MS = 2000;
  const POLL_IDLE_MS = 15000;

  class BridgeError extends Error {
    constructor(message, status = 0, payload = null) {
      super(message);
      this.name = "BridgeError";
      this.status = status;
      this.payload = payload;
    }
  }

  function parseGitHubPage(locationLike) {
    const pathname = locationLike.pathname || "/";
    let match = pathname.match(/^\/([^/]+)\/([^/]+)\/pull\/(\d+)(?:\/|$)/);
    if (match) {
      const repository = `${decodeURIComponent(match[1])}/${decodeURIComponent(match[2])}`;
      const number = Number(match[3]);
      return {
        type: "pull_request",
        key: `github:${repository.toLowerCase()}:pr:${number}`,
        repository,
        pr_number: number,
        workflow_run_id: null
      };
    }
    match = pathname.match(/^\/([^/]+)\/([^/]+)\/actions\/runs\/(\d+)(?:\/|$)/);
    if (match) {
      const repository = `${decodeURIComponent(match[1])}/${decodeURIComponent(match[2])}`;
      const runID = Number(match[3]);
      return {
        type: "workflow_run",
        key: `github:${repository.toLowerCase()}:run:${runID}`,
        repository,
        pr_number: null,
        workflow_run_id: runID
      };
    }
    return null;
  }

  function createGMAdapter(source = global.GM || {}) {
    const legacy = global;
    const getValue = source.getValue || legacy.GM_getValue;
    const setValue = source.setValue || legacy.GM_setValue;
    const openInTab = source.openInTab || legacy.GM_openInTab;
    const registerMenuCommand = source.registerMenuCommand || legacy.GM_registerMenuCommand;
    const xmlHttpRequest = source.xmlHttpRequest || legacy.GM_xmlhttpRequest;

    return {
      getValue: (key, fallback) => Promise.resolve(
        getValue ? getValue.call(source, key, fallback) : fallback
      ),
      setValue: (key, value) => Promise.resolve(
        setValue ? setValue.call(source, key, value) : undefined
      ),
      openInTab: (url) => {
        if (openInTab) {
          return openInTab.call(source, url, { active: true, insert: true });
        }
        return global.open(url, "_blank", "noopener");
      },
      registerMenuCommand: (label, callback) => {
        if (registerMenuCommand) {
          registerMenuCommand.call(source, label, callback);
        }
      },
      request: (options) => new Promise((resolve, reject) => {
        if (!xmlHttpRequest) {
          reject(new BridgeError("GM.xmlHttpRequest is unavailable."));
          return;
        }
        let settled = false;
        const finish = (callback) => (value) => {
          if (settled) return;
          settled = true;
          callback(value);
        };
        const onload = finish(resolve);
        const onerror = finish(() => reject(new BridgeError("Browser Bridge is offline.")));
        const ontimeout = finish(() => reject(new BridgeError("Browser Bridge timed out.")));
        try {
          const result = xmlHttpRequest.call(source, {
            timeout: 4000,
            ...options,
            onload,
            onerror,
            ontimeout
          });
          if (result && typeof result.then === "function") {
            result.then(onload, onerror);
          }
        } catch (error) {
          onerror(error);
        }
      })
    };
  }

  class BridgeClient {
    constructor(gm) {
      this.gm = gm;
      this.baseURL = null;
      this.instanceID = null;
      this.token = null;
      this.client = null;
      this.discovery = null;
    }

    async discover() {
      const cached = Number(await this.gm.getValue(STORAGE.port, 0));
      const ports = cached
        ? [cached, ...DISCOVERY_PORTS.filter((port) => port !== cached)]
        : DISCOVERY_PORTS;
      for (const port of ports) {
        try {
          const baseURL = `http://127.0.0.1:${port}`;
          const discovery = await this.rawRequest(
            baseURL,
            "GET",
            "/.well-known/ghpr-browser-bridge"
          );
          if (discovery.protocol === "ghpr.browser-bridge/v1") {
            this.baseURL = baseURL;
            this.discovery = discovery;
            this.instanceID = discovery.instance_id;
            const previousInstance = await this.gm.getValue(STORAGE.instance, null);
            if (previousInstance && previousInstance !== discovery.instance_id) {
              await this.gm.setValue(STORAGE.token, null);
            }
            await this.gm.setValue(STORAGE.port, port);
            await this.gm.setValue(STORAGE.instance, discovery.instance_id);
            this.token = await this.gm.getValue(STORAGE.token, null);
            return discovery;
          }
        } catch (_) {
          // Discovery is deliberately silent when ghpr-view is not running.
        }
      }
      this.baseURL = null;
      this.discovery = null;
      this.client = null;
      return null;
    }

    async authenticate() {
      if (!this.baseURL || !this.token) return null;
      try {
        this.client = await this.request("GET", "/api/v1/client");
        return this.client;
      } catch (error) {
        if (error.status === 401) {
          this.token = null;
          this.client = null;
          await this.gm.setValue(STORAGE.token, null);
          return null;
        }
        throw error;
      }
    }

    async pair(onState, requiredScopes = [], returnURL = null) {
      if (!this.baseURL) throw new BridgeError("ghpr-view is not running.");
      onState?.("Requesting native approval…");
      const descriptor = { ...CLIENT, required_scopes: requiredScopes };
      const pairing = await this.request("POST", "/api/v1/pairings", descriptor, false);
      let pairingURL = pairing.pairing_url;
      if (returnURL) {
        const parsedReturn = new URL(returnURL);
        if (parsedReturn.origin === "https://github.com" && parseGitHubPage(parsedReturn)) {
          const url = new URL(pairingURL);
          url.searchParams.set("return", parsedReturn.href);
          pairingURL = url.href;
        }
      }
      this.gm.openInTab(pairingURL);
      const deadline = Date.now() + 5 * 60 * 1000;
      while (Date.now() < deadline) {
        const status = await this.request(
          "GET",
          `/api/v1/pairings/${encodeURIComponent(pairing.request_id)}?secret=${encodeURIComponent(pairing.pairing_secret)}`,
          null,
          false
        );
        onState?.(`Waiting for approval · ${status.state}`);
        if (status.state === "approved" && status.token) {
          this.token = status.token;
          this.client = status.client;
          await this.gm.setValue(STORAGE.token, status.token);
          return status.client;
        }
        if (status.state === "denied" || status.state === "expired") {
          throw new BridgeError(`Pairing was ${status.state}.`);
        }
        await new Promise((resolve) => global.setTimeout(resolve, 1000));
      }
      throw new BridgeError("Pairing approval timed out.");
    }

    async request(method, path, body = null, authenticated = true) {
      if (!this.baseURL) throw new BridgeError("Browser Bridge is offline.");
      return this.rawRequest(this.baseURL, method, path, body, authenticated);
    }

    async rawRequest(baseURL, method, path, body = null, authenticated = false) {
      const headers = { Accept: "application/json" };
      if (body !== null) headers["Content-Type"] = "application/json";
      if (authenticated && this.token) headers.Authorization = `Bearer ${this.token}`;
      const response = await this.gm.request({
        method,
        url: `${baseURL}${path}`,
        headers,
        data: body === null ? undefined : JSON.stringify(body)
      });
      let payload = null;
      try {
        payload = response.responseText ? JSON.parse(response.responseText) : null;
      } catch (_) {
        throw new BridgeError("Browser Bridge returned invalid JSON.", response.status);
      }
      if (response.status < 200 || response.status >= 300) {
        const message = payload?.error?.message || `Browser Bridge returned ${response.status}.`;
        throw new BridgeError(message, response.status, payload);
      }
      return payload;
    }
  }

  function createElement(document, tagName, options = {}, children = []) {
    const element = document.createElement(tagName);
    if (options.className) element.className = options.className;
    if (options.text !== undefined) element.textContent = options.text;
    if (options.title) element.title = options.title;
    if (options.type) element.type = options.type;
    if (options.id) element.id = options.id;
    if (options.dataset) {
      for (const [key, value] of Object.entries(options.dataset)) {
        element.dataset[key] = value;
      }
    }
    if (options.attributes) {
      for (const [key, value] of Object.entries(options.attributes)) {
        element.setAttribute(key, value);
      }
    }
    for (const child of children.flat()) {
      if (child) element.append(child);
    }
    return element;
  }

  function button(document, label, callback, className = "ghpr-button") {
    const element = createElement(document, "button", {
      className,
      text: label,
      type: "button"
    });
    element.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      callback(event);
    });
    return element;
  }

  function toneForVerdict(verdict) {
    if (verdict === "likely_flaky") return "warning";
    if (verdict === "likely_related") return "danger";
    return "analysis";
  }

  function labelForVerdict(verdict) {
    if (verdict === "likely_flaky") return "Likely flaky";
    if (verdict === "likely_related") return "Likely related";
    return "Needs investigation";
  }

  function isVersionNewer(latest, current) {
    const parse = (value) => {
      const normalized = String(value || "").trim().replace(/^v/i, "");
      const [core, prerelease = ""] = normalized.split("-", 2);
      const parts = core.split(".");
      if (!parts.length || parts.length > 4 || parts.some((part) => !/^\d+$/.test(part))) {
        return null;
      }
      return {
        parts: parts.map(Number),
        prerelease
      };
    };
    const available = parse(latest);
    const installed = parse(current);
    if (!available || !installed) return false;
    const length = Math.max(available.parts.length, installed.parts.length);
    for (let index = 0; index < length; index += 1) {
      const difference = (available.parts[index] || 0) - (installed.parts[index] || 0);
      if (difference !== 0) return difference > 0;
    }
    return !available.prerelease && Boolean(installed.prerelease);
  }

  function isConversationSurface(locationLike) {
    const pathname = locationLike?.pathname || "/";
    return /^\/[^/]+\/[^/]+\/pull\/\d+\/?(?:conversation\/?)?$/.test(pathname);
  }

  function semanticTargets(document, slot) {
    const selectors = {
      "pr.header.actions": [
        "[data-testid='issue-header'] .gh-header-actions",
        ".gh-header-actions",
        ".gh-header-show"
      ],
      "pr.header.status": [
        "[data-testid='issue-header'] .gh-header-meta",
        ".gh-header-meta"
      ],
      "pr.mergebox.after": [
        "[data-testid='merge-box']",
        "#partial-pull-merging",
        ".mergeability-details"
      ],
      "pr.conversation.after-checks": [
        ".js-checks-summarized",
        "[data-testid='checks-summary']",
        "#partial-pull-merging"
      ],
      "checks.summary.actions": [
        "[data-testid='checks-summary']",
        "#checks_tab .Box-header",
        ".checks-listing"
      ],
      "checks.run.trailing": [
        "[data-testid='check-run-row']",
        ".js-check-run",
        ".CheckRun"
      ],
      "checks.job.trailing": [
        "[data-testid='check-job-row']",
        ".js-check-run",
        ".CheckRun"
      ],
      "files.toolbar.actions": [
        "[data-testid='files-toolbar']",
        "#files .pr-toolbar",
        ".diffbar"
      ],
      "files.diff.line-decoration": [
        "table.diff-table"
      ]
    };
    const matches = [];
    for (const selector of selectors[slot] || []) {
      for (const element of document.querySelectorAll(selector)) {
        if (!matches.includes(element)) matches.push(element);
      }
      if (matches.length) break;
    }
    return matches;
  }

  function installStyles(document) {
    if (document.getElementById(STYLE_ID)) return;
    const style = createElement(document, "style", { id: STYLE_ID });
    style.textContent = `
      #${ROOT_ID}, [${MANAGED_ATTRIBUTE}] {
        --ghpr-purple: #6f6baf;
        --ghpr-purple-strong: #54508f;
        --ghpr-peach: #f2cfb3;
        --ghpr-ink: var(--fgColor-default, #1f2328);
        --ghpr-muted: var(--fgColor-muted, #656d76);
        --ghpr-panel: var(--bgColor-default, #ffffff);
        --ghpr-border: var(--borderColor-default, #d0d7de);
        color: var(--ghpr-ink);
        font: 12px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }
      #${ROOT_ID} {
        background: var(--ghpr-panel); border: 1px solid var(--ghpr-border);
        border-radius: 8px; box-sizing: border-box; color: var(--ghpr-ink);
        isolation: isolate; padding: 12px; text-align: left; white-space: normal;
      }
      #${ROOT_ID}, #${ROOT_ID} *, #${ROOT_ID} *::before, #${ROOT_ID} *::after {
        box-sizing: border-box;
      }
      #${ROOT_ID}.ghpr-in-sidebar {
        display: block; margin: 0 0 16px; width: 100%;
      }
      #${ROOT_ID}.ghpr-floating {
        box-shadow: 0 8px 24px rgba(31, 35, 40, .2);
        max-height: min(680px, calc(100vh - 112px));
        max-height: min(680px, calc(100dvh - 112px));
        overflow-x: hidden; overflow-y: auto; overscroll-behavior: contain;
        position: fixed; right: 16px; top: 88px; width: 320px; z-index: 2147483000;
      }
      #${ROOT_ID}.ghpr-compact {
        max-height: none; overflow: hidden; padding: 8px 10px;
      }
      #${ROOT_ID}.ghpr-compact .ghpr-panel-body { display: none; }
      #${ROOT_ID}.ghpr-compact .ghpr-panel-subtitle { display: none; }
      #${ROOT_ID}.ghpr-floating.ghpr-compact {
        max-height: none; width: min(220px, calc(100vw - 32px));
      }
      .ghpr-panel-head {
        align-items: center; display: flex; gap: 8px; min-height: 22px; min-width: 0;
      }
      .ghpr-panel-mark {
        align-items: center; background: var(--ghpr-purple); border-radius: 6px; color: white;
        display: inline-flex; flex: 0 0 auto; font-size: 11px; font-weight: 800;
        height: 22px; justify-content: center; width: 22px;
      }
      #${ROOT_ID}[data-state="running"] .ghpr-panel-mark {
        animation: ghpr-pulse 1.2s infinite; background: var(--ghpr-peach); color: var(--ghpr-ink);
      }
      @keyframes ghpr-pulse { 50% { opacity: .45; transform: scale(.88); } }
      .ghpr-panel-identity { flex: 1 1 auto; min-width: 0; }
      .ghpr-panel-title { font-size: 13px; font-weight: 750; letter-spacing: .01em; }
      .ghpr-panel-subtitle {
        color: var(--ghpr-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .ghpr-panel-toggle {
        appearance: none; background: transparent; border: 0; border-radius: 6px;
        color: var(--ghpr-muted); cursor: pointer; flex: 0 0 auto; font: inherit;
        height: 28px; padding: 0; width: 28px;
      }
      .ghpr-panel-toggle:hover { background: color-mix(in srgb, var(--ghpr-purple) 10%, var(--ghpr-panel)); }
      .ghpr-panel-body { margin-top: 8px; }
      .ghpr-update-notice {
        align-items: center; background: color-mix(in srgb, var(--ghpr-peach) 28%, var(--ghpr-panel));
        border: 1px solid color-mix(in srgb, var(--ghpr-peach) 70%, var(--ghpr-border));
        border-radius: 7px; display: flex; gap: 8px; justify-content: space-between;
        margin-bottom: 8px; padding: 8px;
      }
      .ghpr-update-copy { min-width: 0; }
      .ghpr-update-copy strong { display: block; }
      .ghpr-update-copy span { color: var(--ghpr-muted); display: block; font-size: 11px; }
      #${ROOT_ID} .ghpr-section {
        border-top: 1px solid var(--ghpr-border); margin: 8px 0 0; padding: 8px 0 0;
      }
      .ghpr-section-label {
        color: var(--ghpr-muted); font-size: 10px; font-weight: 700;
        letter-spacing: .08em; margin-bottom: 4px; text-transform: uppercase;
      }
      .ghpr-button, .ghpr-panel-action {
        appearance: none; border: 1px solid var(--ghpr-border); border-radius: 6px;
        background: var(--ghpr-panel); color: var(--ghpr-ink); cursor: pointer;
        font: inherit; line-height: 1.35; margin: 0; min-width: 0; padding: 6px 8px;
      }
      .ghpr-panel-action {
        border: 0; display: block; min-height: 30px; overflow-wrap: anywhere;
        position: static; text-align: left; white-space: normal; width: 100%;
      }
      #${ROOT_ID} summary {
        cursor: pointer; font-weight: 650; min-height: 30px; padding: 6px 8px;
      }
      .ghpr-panel-action:hover:not(:disabled), .ghpr-button:hover:not(:disabled) {
        background: color-mix(in srgb, var(--ghpr-purple) 10%, var(--ghpr-panel));
      }
      .ghpr-button-primary { background: var(--ghpr-purple); border-color: var(--ghpr-purple); color: white; }
      .ghpr-panel-action:disabled, .ghpr-button:disabled,
      .ghpr-badge.ghpr-busy,
      [aria-disabled="true"].ghpr-panel-action,
      [aria-disabled="true"].ghpr-button {
        background: rgba(110, 118, 129, .12);
        border-color: var(--ghpr-border);
        color: color-mix(in srgb, var(--ghpr-ink) 45%, transparent);
        cursor: not-allowed;
      }
      .ghpr-action-row { align-items: center; display: flex; flex-wrap: wrap; gap: 6px; min-width: 0; }
      .ghpr-badge {
        border: 1px solid currentColor; border-radius: 999px; display: inline-flex;
        font-size: 11px; font-weight: 650; line-height: 20px; padding: 0 7px; white-space: nowrap;
      }
      .ghpr-tone-warning { color: #9a6700; background: rgba(242, 207, 179, .25); }
      .ghpr-tone-danger { color: #cf222e; background: rgba(255, 129, 130, .12); }
      .ghpr-tone-success { color: #1a7f37; background: rgba(63, 185, 80, .12); }
      .ghpr-tone-analysis, .ghpr-tone-info { color: var(--ghpr-purple-strong); background: rgba(111, 107, 175, .12); }
      .ghpr-card {
        border: 1px solid var(--ghpr-border); border-left: 3px solid var(--ghpr-purple);
        border-radius: 8px; background: var(--ghpr-panel); margin: 10px 0; padding: 12px;
      }
      .ghpr-card-head { align-items: center; display: flex; gap: 8px; justify-content: space-between; }
      .ghpr-card-title { font-weight: 750; }
      .ghpr-card-summary { color: var(--ghpr-muted); margin: 7px 0; }
      .ghpr-metrics { display: grid; gap: 5px 12px; grid-template-columns: repeat(3, minmax(0, 1fr)); margin: 8px 0; }
      .ghpr-metric strong { display: block; font-size: 13px; }
      .ghpr-metric span { color: var(--ghpr-muted); font-size: 10px; }
      .ghpr-check-tools { align-items: center; display: inline-flex; gap: 5px; margin-left: 8px; }
      .ghpr-fallback { max-height: 160px; overflow: auto; }
      .ghpr-error { color: #cf222e; font-size: 11px; margin-top: 5px; }
      @media (max-width: 1100px) {
        #${ROOT_ID}.ghpr-floating {
          bottom: 8px; max-height: min(56vh, 420px); padding: 10px;
          right: 8px; top: auto; width: min(320px, calc(100vw - 16px));
        }
      }
      @media (max-width: 720px) {
        #${ROOT_ID}.ghpr-floating {
          left: 8px; max-height: min(68vh, 520px); right: 8px; width: auto;
        }
        #${ROOT_ID}.ghpr-floating.ghpr-compact {
          left: auto; max-height: none; width: min(220px, calc(100vw - 16px));
        }
        .ghpr-panel-action, #${ROOT_ID} summary { min-height: 40px; padding: 10px; }
        .ghpr-action-row { align-items: stretch; flex-direction: column; }
        .ghpr-action-row .ghpr-button { min-height: 40px; width: 100%; }
        .ghpr-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
        .ghpr-check-tools { flex-wrap: wrap; margin-left: 4px; }
      }
      @media (max-width: 420px) {
        .ghpr-metrics { grid-template-columns: 1fr; }
      }
      @media (prefers-reduced-motion: reduce) {
        #${ROOT_ID}[data-state="running"] .ghpr-panel-mark { animation: none; }
      }
      @media (prefers-color-scheme: dark) {
        #${ROOT_ID}.ghpr-floating { box-shadow: 0 8px 24px rgba(0, 0, 0, .45); }
      }
    `;
    (document.head || document.documentElement).append(style);
  }

  class GhprGitHubApp {
    constructor({ window, document, gm }) {
      this.window = window;
      this.document = document;
      this.gm = gm;
      this.bridge = new BridgeClient(gm);
      this.page = null;
      this.snapshot = null;
      this.timer = null;
      this.observer = null;
      this.refreshing = false;
      this.stopped = false;
      this.navigationKey = null;
      this.panelSurfaceKey = null;
      this.panelExpanded = true;
      this.pendingSkillRuns = new Set();
    }

    async start() {
      installStyles(this.document);
      this.gm.registerMenuCommand("Open in ghpr", () => this.openApp());
      this.gm.registerMenuCommand("Analyze current PR", () => {
        this.invokeAction({ kind: "run_skill", skill_id: "ci.failure.classify_flaky" });
      });
      this.observeNavigation();
      await this.refresh();
      return this;
    }

    stop() {
      this.stopped = true;
      if (this.timer) this.window.clearTimeout(this.timer);
      this.observer?.disconnect();
      this.cleanup();
    }

    observeNavigation() {
      let queued = false;
      const schedule = () => {
        if (queued) return;
        queued = true;
        this.window.setTimeout(() => {
          queued = false;
          const key = `${this.window.location.pathname}${this.window.location.search}`;
          if (key !== this.navigationKey) this.refresh();
        }, 150);
      };
      this.observer = new this.window.MutationObserver(schedule);
      this.observer.observe(this.document.documentElement, { childList: true, subtree: true });
      this.window.addEventListener("popstate", schedule);
      this.window.addEventListener("ghpr:navigation", schedule);
    }

    async refresh() {
      if (this.refreshing || this.stopped) return;
      this.refreshing = true;
      this.navigationKey = `${this.window.location.pathname}${this.window.location.search}`;
      try {
        this.page = parseGitHubPage(this.window.location);
        if (!this.page) {
          this.cleanup();
          return;
        }
        const discovery = await this.bridge.discover();
        if (!discovery) {
          this.cleanup();
          return;
        }
        const client = await this.bridge.authenticate();
        if (!client) {
          this.renderConnect();
          return;
        }
        const query = this.page.type === "pull_request"
          ? `repository=${encodeURIComponent(this.page.repository)}&number=${this.page.pr_number}`
          : `repository=${encodeURIComponent(this.page.repository)}&run_id=${this.page.workflow_run_id}`;
        this.snapshot = await this.bridge.request("GET", `/api/v1/page?${query}`);
        this.render();
      } catch (error) {
        if (error.status === 401) {
          this.renderConnect();
        } else {
          this.renderTransientError(error.message);
        }
      } finally {
        this.refreshing = false;
        this.scheduleNextRefresh();
      }
    }

    scheduleNextRefresh() {
      if (this.stopped) return;
      if (this.timer) this.window.clearTimeout(this.timer);
      const active = this.snapshot?.runs?.some((run) =>
        run.status === "queued" || run.status === "running"
      );
      this.timer = this.window.setTimeout(
        () => this.refresh(),
        active ? POLL_ACTIVE_MS : POLL_IDLE_MS
      );
    }

    cleanup(clearSnapshot = true) {
      this.document.getElementById(ROOT_ID)?.remove();
      for (const node of this.document.querySelectorAll(`[${MANAGED_ATTRIBUTE}]`)) {
        node.remove();
      }
      if (clearSnapshot) this.snapshot = null;
    }

    panelMount() {
      const sidebar = this.document.querySelector("#partial-discussion-sidebar");
      if (!sidebar) {
        return { host: this.document.body, inSidebar: false, before: null };
      }
      const assignees = sidebar.querySelector(
        ":scope > .sidebar-assignee, :scope > [data-testid='assignees-section'], :scope > [data-testid='sidebar-assignees']"
      );
      const reviewers = sidebar.querySelector(
        ":scope > .sidebar-reviewers, :scope > [data-testid='reviewers-section'], :scope > [data-testid='sidebar-reviewers']"
      );
      return {
        host: sidebar,
        inSidebar: true,
        before: assignees || reviewers?.nextElementSibling || sidebar.firstElementChild
      };
    }

    root() {
      let root = this.document.getElementById(ROOT_ID);
      const mount = this.panelMount();
      const surfaceKey = this.window.location.pathname;
      if (surfaceKey !== this.panelSurfaceKey) {
        this.panelSurfaceKey = surfaceKey;
        this.panelExpanded = isConversationSurface(this.window.location);
      }
      if (!root) {
        root = createElement(this.document, "section", {
          id: ROOT_ID,
          attributes: { "aria-label": "ghpr local PR tools" }
        });
      }
      root.className = [
        mount.inSidebar ? "discussion-sidebar-item ghpr-in-sidebar" : "ghpr-floating",
        this.panelExpanded ? "" : "ghpr-compact"
      ].filter(Boolean).join(" ");
      if (mount.before) {
        if (root.parentElement !== mount.host || root.nextElementSibling !== mount.before) {
          mount.host.insertBefore(root, mount.before);
        }
      } else if (root.parentElement !== mount.host || root.nextElementSibling) {
        mount.host.append(root);
      }
      root.replaceChildren();
      return root;
    }

    panelHeader(root, subtitle, stateLabel) {
      const initiallyCompact = root.classList.contains("ghpr-compact");
      const toggle = button(this.document, initiallyCompact ? "+" : "−", () => {
        const compact = root.classList.toggle("ghpr-compact");
        this.panelExpanded = !compact;
        toggle.textContent = compact ? "+" : "−";
        toggle.setAttribute("aria-expanded", String(!compact));
        toggle.setAttribute(
          "aria-label",
          compact ? "Expand ghpr card" : "Collapse ghpr card"
        );
      }, "ghpr-panel-toggle");
      toggle.setAttribute("aria-expanded", String(!initiallyCompact));
      toggle.setAttribute(
        "aria-label",
        initiallyCompact ? "Expand ghpr card" : "Collapse ghpr card"
      );
      return createElement(this.document, "div", { className: "ghpr-panel-head" }, [
        createElement(this.document, "span", {
          className: "ghpr-panel-mark",
          text: "g",
          attributes: { "aria-hidden": "true" }
        }),
        createElement(this.document, "div", { className: "ghpr-panel-identity" }, [
          createElement(this.document, "div", { className: "ghpr-panel-title", text: "ghpr" }),
          createElement(this.document, "div", { className: "ghpr-panel-subtitle", text: subtitle })
        ]),
        createElement(this.document, "span", {
          className: `ghpr-badge ghpr-tone-${stateLabel === "Update" ? "warning" : "analysis"}`,
          text: stateLabel
        }),
        toggle
      ]);
    }

    renderConnect() {
      this.cleanup();
      const root = this.root();
      root.dataset.state = "connect";
      const body = createElement(this.document, "div", { className: "ghpr-panel-body" });
      const updateNotice = this.renderUpdateNotice();
      if (updateNotice) body.append(updateNotice);
      body.append(createElement(this.document, "p", {
        className: "ghpr-card-summary",
        text: "Connect this userscript to the local ghpr Browser Bridge."
      }));
      const connect = button(this.document, "Connect ghpr", async () => {
        connect.disabled = true;
        connect.textContent = "Waiting for approval…";
        try {
          await this.bridge.pair((message) => {
            connect.textContent = message;
          });
          await this.refresh();
        } catch (error) {
          connect.disabled = false;
          connect.textContent = "Connect ghpr";
          connect.title = error.message;
        }
      }, "ghpr-button ghpr-button-primary");
      connect.setAttribute("aria-label", "Connect ghpr for GitHub");
      body.append(connect);
      root.append(
        this.panelHeader(
          root,
          "Local PR tools",
          this.updateAvailable() ? "Update" : "Connect"
        ),
        body
      );
    }

    render() {
      this.cleanup(false);
      const root = this.root();
      if (!this.snapshot) return;
      const currentRun = this.snapshot.runs.find((run) =>
        run.status === "queued" || run.status === "running"
      );
      const analysis = this.snapshot.analyses[0] || null;
      root.dataset.state = currentRun ? "running" : this.updateAvailable() ? "update" : "idle";
      const body = this.renderPanel();
      root.append(
        this.panelHeader(
          root,
          analysis
            ? `${labelForVerdict(analysis.verdict)} · ${analysis.confidence} confidence`
            : "Local PR operations",
          currentRun ? "Running" : this.updateAvailable() ? "Update" : "Ready"
        ),
        body
      );
      if (isConversationSurface(this.window.location)) this.renderAnalysisCard();
      this.renderCheckRows();
      this.renderContributions(body);
    }

    renderPanel() {
      const panel = createElement(this.document, "div", {
        className: "ghpr-panel-body"
      });
      const updateNotice = this.renderUpdateNotice();
      if (updateNotice) panel.append(updateNotice);
      const analysis = this.snapshot.analyses[0] || null;
      const actions = this.panelSection("Actions");
      if (this.hasScope("skill:run")) {
        actions.append(
          this.runAction("Explain CI Failure", {
            kind: "run_skill",
            skill_id: "ci.failure.explain"
          }),
          this.runAction("Classify Flaky", {
            kind: "run_skill",
            skill_id: "ci.failure.classify_flaky"
          })
        );
        const runnableSkills = this.snapshot.skills.filter((skill) => skill.is_runnable);
        if (runnableSkills.length) {
          const skills = createElement(this.document, "details", { className: "ghpr-section" });
          skills.append(createElement(this.document, "summary", { text: "Run Skill" }));
          for (const skill of runnableSkills) {
            skills.append(this.runAction(skill.display_name, {
              kind: "run_skill",
              skill_id: skill.id
            }));
          }
          actions.append(skills);
        }
      } else {
        actions.append(this.permissionPrompt(
          "Run Skills",
          "skill:run",
          "Analysis actions are off for this client."
        ));
      }
      panel.append(actions);

      const running = this.snapshot.runs.filter((run) =>
        run.status === "queued" || run.status === "running"
      );
      if (running.length) {
        const runs = this.panelSection("Running");
        for (const run of running) {
          const rowChildren = [
            createElement(this.document, "span", {
              text: run.progress_message || `${run.status} · ${run.skill_id}`
            })
          ];
          if (this.hasScope("detail:open")) {
            rowChildren.push(button(this.document, "View live log", () =>
              this.invokeAction({ kind: "open_detail", run_id: run.id })
            ));
          } else {
            rowChildren.push(this.permissionPrompt("Open live log", "detail:open", "Open local analysis is off for this client."));
          }
          if (this.hasScope("skill:cancel")) {
            rowChildren.push(button(this.document, "Cancel", () =>
              this.invokeAction({ kind: "cancel_run", run_id: run.id })
            ));
          } else {
            rowChildren.push(this.permissionPrompt("Cancel Skill runs", "skill:cancel", "Cancel permission is required for this action."));
          }
          const row = createElement(this.document, "div", {
            className: "ghpr-action-row"
          }, rowChildren);
          runs.append(row);
        }
        panel.append(runs);
      }

      const finished = this.snapshot.runs.filter((run) =>
        run.status === "completed" || run.status === "failed" || run.status === "cancelled"
      ).slice(0, 3);
      if (finished.length) {
        const results = this.panelSection("Recent runs");
        for (const run of finished) {
          if (run.status === "completed" && run.result) {
            if (this.hasScope("detail:open")) {
              results.append(this.panelAction(
                run.result.title || run.skill_id,
                () => this.invokeAction({ kind: "open_detail", run_id: run.id })
              ));
            } else {
              results.append(this.permissionPrompt("Open analysis", "detail:open", "Open local analysis is off for this client."));
            }
          } else {
            const rowChildren = [
              createElement(this.document, "span", {
                text: `${run.skill_id} · ${run.error || run.status}`
              })
            ];
            if (this.hasScope("skill:run")) {
              rowChildren.push(this.runAction(
                "Retry",
                { kind: "retry_run", run_id: run.id },
                "ghpr-button"
              ));
            } else {
              rowChildren.push(this.permissionPrompt("Retry Skill", "skill:run", "Run permission is required for retry."));
            }
            const row = createElement(this.document, "div", {
              className: "ghpr-action-row"
            }, rowChildren);
            results.append(row);
          }
        }
        panel.append(results);
      }


      const tags = this.panelSection("Local ghpr tags");
      if (this.hasScope("tag:write")) {
        for (const [value, label] of [
          ["flaky", "Flaky"],
          ["not_flaky", "Not flaky"],
          ["needs_investigation", "Needs investigation"]
        ]) {
          const selected = this.snapshot.tags.includes(value);
          tags.append(this.panelAction(`${selected ? "✓ " : ""}${label}`, () =>
            this.invokeAction({
              kind: selected ? "remove_tag" : "set_tag",
              tag: value
            })
          ));
        }
      } else {
        tags.append(this.permissionPrompt(
          "Edit local ghpr tags",
          "tag:write",
          "Local ghpr tag changes are off for this client."
        ));
      }
      panel.append(tags);

      const links = this.panelSection("");
      if (analysis) {
        if (this.hasScope("detail:open")) {
          links.append(this.panelAction("Open Full Analysis", () =>
            this.invokeAction({ kind: "open_detail", analysis_id: analysis.id })
          ));
        } else {
          links.append(this.permissionPrompt("Open Full Analysis", "detail:open", "Open local analysis is off for this client."));
        }
      }
      if (this.hasScope("app:open")) {
        links.append(this.panelAction("Open in ghpr-view", () =>
          this.invokeAction({ kind: "open_app" })
        ));
      } else {
        links.append(this.permissionPrompt("Open ghpr-view", "app:open", "Open ghpr-view permission is required."));
      }
      if (links.children.length) panel.append(links);
      return panel;
    }

    panelSection(label) {
      const section = createElement(this.document, "div", { className: "ghpr-section" });
      if (label) {
        section.append(createElement(this.document, "div", {
          className: "ghpr-section-label",
          text: label
        }));
      }
      return section;
    }

    hasScope(scope) {
      return Boolean(this.bridge.client?.scopes?.includes(scope));
    }

    actionScope(action) {
      if (action.kind === "run_skill" ||
          action.kind === "retry_run" ||
          action.kind === "rerun_failed_jobs") {
        return "skill:run";
      }
      if (action.kind === "cancel_run") return "skill:cancel";
      if (action.kind === "set_tag" || action.kind === "remove_tag") return "tag:write";
      if (action.kind === "open_detail") return "detail:open";
      if (action.kind === "open_app" || action.kind === "show_pr") return "app:open";
      return null;
    }

    permissionPrompt(label, scope, detail) {
      const grant = button(this.document, `Grant ${label}`, async () => {
        grant.disabled = true;
        try {
          grant.textContent = "Requesting approval";
          const currentURL = this.window.location.origin === "https://github.com" && this.page
            ? this.window.location.href
            : null;
          await this.bridge.pair((message) => {
            grant.textContent = message;
          }, [scope], currentURL);
          if (!this.hasScope(scope)) {
            throw new Error(`The approval did not grant ${scope}.`);
          }
          await this.refresh();
          this.renderTransientError(`${PERMISSION_LABELS[scope] || scope} enabled. Choose the action again.`);
        } catch (error) {
          grant.disabled = false;
          grant.textContent = `Grant ${label}`;
          this.renderTransientError(error.message);
        }
      }, "ghpr-button ghpr-button-primary");
      return createElement(this.document, "aside", {
        className: "ghpr-update-notice ghpr-permission-notice",
        attributes: { role: "status" }
      }, [
        createElement(this.document, "div", { className: "ghpr-update-copy" }, [
          createElement(this.document, "strong", { text: `${scope} required` }),
          createElement(this.document, "span", { text: detail })
        ]),
        grant
      ]);
    }

    updateAvailable() {
      return isVersionNewer(
        this.bridge.discovery?.official_userscript_version,
        CLIENT.version
      );
    }

    renderUpdateNotice() {
      const latest = this.bridge.discovery?.official_userscript_version;
      if (!this.updateAvailable() || !this.bridge.baseURL) return null;
      const update = button(this.document, "Update", () => {
        this.gm.openInTab(`${this.bridge.baseURL}/install/ghpr.user.js`);
      }, "ghpr-button ghpr-button-primary");
      update.setAttribute("aria-label", `Update ghpr for GitHub to ${latest}`);
      return createElement(this.document, "aside", {
        className: "ghpr-update-notice",
        attributes: { role: "status" }
      }, [
        createElement(this.document, "div", { className: "ghpr-update-copy" }, [
          createElement(this.document, "strong", { text: "Userscript update available" }),
          createElement(this.document, "span", {
            text: `${CLIENT.version} → ${latest}`
          })
        ]),
        update
      ]);
    }

    panelAction(label, callback) {
      return button(this.document, label, callback, "ghpr-panel-action");
    }

    activeRunForSkill(skillID) {
      if (!skillID) return null;
      return this.snapshot?.runs?.find((run) =>
        run.skill_id === skillID &&
        (run.status === "queued" || run.status === "running")
      ) || null;
    }

    actionSkillID(action) {
      if (!action) return null;
      if (action.kind === "run_skill") return action.skill_id || null;
      if (action.kind === "retry_run") {
        return this.snapshot?.runs?.find((run) => run.id === action.run_id)?.skill_id || null;
      }
      return null;
    }

    runActionBusy(action) {
      const skillID = this.actionSkillID(action);
      if (!skillID) return false;
      return this.pendingSkillRuns.has(skillID) ||
        Boolean(this.activeRunForSkill(skillID));
    }

    markRunActionBusy(control, label) {
      if ("disabled" in control) control.disabled = true;
      control.setAttribute("aria-disabled", "true");
      control.classList.add("ghpr-busy");
      control.title = "This Skill is already running. Wait for it to finish or cancel it.";
      if (label !== null) control.textContent = `${label} · Running`;
    }

    runAction(label, action, className = "ghpr-panel-action") {
      const control = button(this.document, label, () => {
        if (control.disabled) return;
        this.markRunActionBusy(control, label);
        this.invokeAction(action);
      }, className);
      if (this.runActionBusy(action)) this.markRunActionBusy(control, label);
      return control;
    }

    async withRunGuard(action, operation) {
      const skillID = this.actionSkillID(action);
      if (skillID) {
        if (this.pendingSkillRuns.has(skillID)) return;
        if (this.activeRunForSkill(skillID)) {
          this.renderTransientError(`${skillID} is already running.`);
          return;
        }
        this.pendingSkillRuns.add(skillID);
      }
      try {
        await operation();
      } finally {
        if (skillID) this.pendingSkillRuns.delete(skillID);
      }
    }

    renderRunningCard(run) {
      const host = semanticTargets(this.document, "pr.mergebox.after")[0];
      if (!host) return;
      const progress = run.progress_total
        ? `${run.progress_current || 0} / ${run.progress_total}`
        : "In progress";
      const actions = [];
      if (this.hasScope("detail:open")) {
        actions.push(button(this.document, "View live log", () =>
          this.invokeAction({ kind: "open_detail", run_id: run.id })
        ));
      }
      if (this.hasScope("skill:cancel")) {
        actions.push(button(this.document, "Cancel", () =>
          this.invokeAction({ kind: "cancel_run", run_id: run.id })
        ));
      }
      const card = createElement(this.document, "section", {
        className: "ghpr-card ghpr-run-card",
        attributes: { [MANAGED_ATTRIBUTE]: "", "aria-label": "ghpr Skill Running" }
      }, [
        createElement(this.document, "div", { className: "ghpr-card-head" }, [
          createElement(this.document, "span", {
            className: "ghpr-card-title",
            text: run.skill_id
          }),
          createElement(this.document, "span", {
            className: "ghpr-badge ghpr-tone-analysis",
            text: "Running"
          })
        ]),
        createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: run.progress_message || "Waiting for Skill output…"
        }),
        createElement(this.document, "div", { className: "ghpr-metrics" }, [
          this.metric(progress, "Progress"),
          this.metric(run.status, "Status")
        ])
      ]);
      if (actions.length) {
        card.append(createElement(this.document, "div", {
          className: "ghpr-action-row"
        }, actions));
      }
      host.insertAdjacentElement("afterend", card);
    }


    renderAnalysisCard() {
      const currentRun = this.snapshot.runs.find((run) =>
        run.status === "queued" || run.status === "running"
      );
      if (currentRun) {
        this.renderRunningCard(currentRun);
        return;
      }
      const analysis = this.snapshot.analyses[0];
      if (!analysis) return;
      const host = semanticTargets(this.document, "pr.mergebox.after")[0];
      if (!host) return;
      const card = createElement(this.document, "section", {
        className: "ghpr-card",
        attributes: { [MANAGED_ATTRIBUTE]: "", "aria-label": "ghpr CI Analysis" }
      });
      const badge = createElement(this.document, "span", {
        className: `ghpr-badge ghpr-tone-${toneForVerdict(analysis.verdict)}`,
        text: `${labelForVerdict(analysis.verdict)} · ${analysis.confidence}`
      });
      const cardActions = [];
      if (this.hasScope("skill:run")) {
        cardActions.push(button(this.document, "Rerun", () =>
          this.invokeAction({ kind: "rerun_failed_jobs" }, true)
        ));
      }
      if (this.hasScope("tag:write")) {
        cardActions.push(button(this.document, "Mark locally as flaky", () =>
          this.invokeAction({ kind: "set_tag", tag: "flaky" })
        ));
      }
      if (this.hasScope("detail:open")) {
        cardActions.push(button(this.document, "Full Analysis", () =>
          this.invokeAction({ kind: "open_detail", analysis_id: analysis.id })
        ));
      }
      card.append(
        createElement(this.document, "div", { className: "ghpr-card-head" }, [
          createElement(this.document, "span", { className: "ghpr-card-title", text: "ghpr CI Analysis" }),
          badge
        ]),
        createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: analysis.summary
        }),
        createElement(this.document, "div", { className: "ghpr-metrics" }, [
          this.metric(`${analysis.history_matches.length} / ${analysis.history_checked}`, "History"),
          this.metric(
            analysis.relatedness_score == null
              ? "—"
              : `${Math.round(analysis.relatedness_score * 100)}%`,
            "Relatedness"
          ),
          this.metric(analysis.reproduction, "Reproduction")
        ])
      );
      if (cardActions.length) {
        card.append(createElement(this.document, "div", {
          className: "ghpr-action-row"
        }, cardActions));
      }
      host.insertAdjacentElement("afterend", card);
    }

    metric(value, label) {
      return createElement(this.document, "div", { className: "ghpr-metric" }, [
        createElement(this.document, "strong", { text: String(value) }),
        createElement(this.document, "span", { text: label })
      ]);
    }

    renderCheckRows() {
      const analysis = this.snapshot.analyses[0];
      const currentRun = this.snapshot.runs.find((run) =>
        run.status === "queued" || run.status === "running"
      );
      const candidates = semanticTargets(this.document, "checks.run.trailing");
      for (const row of candidates) {
        if (!/\b(failed|failure)\b/i.test(row.textContent || "")) continue;
        if (row.querySelector(":scope > .ghpr-check-tools")) continue;
        const tools = createElement(this.document, "span", {
          className: "ghpr-check-tools",
          attributes: { [MANAGED_ATTRIBUTE]: "" }
        });
        if (currentRun) {
          tools.append(createElement(this.document, "span", {
            className: "ghpr-badge ghpr-tone-analysis",
            text: "Running"
          }));
          if (this.hasScope("detail:open")) {
            tools.append(button(this.document, "View log", () =>
              this.invokeAction({ kind: "open_detail", run_id: currentRun.id })
            ));
          }
        } else {
          if (analysis) {
            tools.append(createElement(this.document, "span", {
              className: `ghpr-badge ghpr-tone-${toneForVerdict(analysis.verdict)}`,
              text: labelForVerdict(analysis.verdict)
            }));
          }
          if (this.hasScope("skill:run")) {
            tools.append(this.runAction(
              "Analyze ▾",
              { kind: "run_skill", skill_id: "ci.failure.classify_flaky" },
              "ghpr-button"
            ));
          }
        }
        if (tools.children.length) row.append(tools);
      }
    }

    async renderContributions(fallbackHost) {
      const fallback = this.panelSection("Extensions");
      fallback.classList.add("ghpr-fallback");
      let fallbackCount = 0;
      const health = [];
      for (const contribution of this.snapshot.contributions) {
        const hosts = semanticTargets(this.document, contribution.slot);
        const healthy = hosts.length > 0;
        health.push({
          page_key: this.page.key,
          slot: contribution.slot,
          healthy,
          detail: healthy ? "Mounted by ghpr for GitHub." : "Semantic anchor was not found."
        });
        if (healthy) {
          for (const host of hosts) {
            host.append(this.renderContribution(contribution));
          }
        } else {
          fallback.append(this.renderContribution(contribution, true));
          fallbackCount += 1;
        }
      }
      if (fallbackCount) fallbackHost.append(fallback);
      for (const report of health) {
        this.bridge.request("POST", "/api/v1/slot-health", report).catch(() => {});
      }
    }

    renderContribution(contribution, fallbackStyle = false) {
      const component = contribution.component;
      const label = component.label || component.text || contribution.id;
      const requiredScope = contribution.action
        ? this.actionScope(contribution.action)
        : null;
      if (requiredScope && !this.hasScope(requiredScope)) {
        const repair = this.permissionPrompt(
          this.contributionActionLabel(contribution.action),
          requiredScope,
          `${requiredScope} is required for this contribution.`
        );
        repair.dataset.ghprContribution = `${contribution.client_id}:${contribution.id}`;
        return repair;
      }
      const canInvoke = Boolean(contribution.action) &&
        (!requiredScope || this.hasScope(requiredScope));
      const runBusy = this.runActionBusy(contribution.action);
      let element;
      let actionControl = null;
      if (component.type === "result_card" && !fallbackStyle) {
        const children = [
          createElement(this.document, "div", { className: "ghpr-card-head" }, [
            createElement(this.document, "span", { className: "ghpr-card-title", text: label }),
            createElement(this.document, "span", {
              className: `ghpr-badge ghpr-tone-${component.tone || "neutral"}`,
              text: "Skill result"
            })
          ])
        ];
        if (component.text) {
          children.push(createElement(this.document, "p", {
            className: "ghpr-card-summary",
            text: component.text
          }));
        }
        if (contribution.action) {
          const actionLabel = this.contributionActionLabel(contribution.action);
          actionControl = button(
            this.document,
            actionLabel,
            () => canInvoke && !actionControl.disabled && this.invokeContribution(contribution),
            "ghpr-button ghpr-button-primary"
          );
          if (runBusy) this.markRunActionBusy(actionControl, actionLabel);
          children.push(createElement(this.document, "div", {
            className: "ghpr-action-row"
          }, [actionControl]));
        }
        element = createElement(this.document, "section", {
          className: "ghpr-card",
          attributes: {
            [MANAGED_ATTRIBUTE]: "",
            "aria-label": label
          }
        }, children);
      } else if (component.type === "badge") {
        element = createElement(this.document, "span", {
          className: `ghpr-badge ghpr-tone-${component.tone || "neutral"}`,
          text: label,
          attributes: { [MANAGED_ATTRIBUTE]: "" }
        });
        if (contribution.action) {
          actionControl = element;
          if (runBusy) {
            this.markRunActionBusy(element, null);
          } else if (canInvoke) {
            element.setAttribute("role", "button");
            element.tabIndex = 0;
            element.addEventListener("click", () => this.invokeContribution(contribution));
          }
        }
      } else {
        element = button(
          this.document,
          label,
          () => canInvoke && !element.disabled && this.invokeContribution(contribution),
          fallbackStyle ? "ghpr-panel-action" : "ghpr-button"
        );
        actionControl = element;
        element.disabled = !canInvoke;
        element.setAttribute(MANAGED_ATTRIBUTE, "");
        if (runBusy) this.markRunActionBusy(element, label);
      }
      if (actionControl && requiredScope && !this.hasScope(requiredScope)) {
        if ("disabled" in actionControl) actionControl.disabled = true;
        actionControl.setAttribute("aria-disabled", "true");
        actionControl.title = `${requiredScope} required`;
      }
      element.dataset.ghprContribution = `${contribution.client_id}:${contribution.id}`;
      return element;
    }

    contributionActionLabel(action) {
      if (action.kind === "open_detail") return "Open Full Analysis";
      if (action.kind === "run_skill") return "Run Skill";
      if (action.kind === "retry_run") return "Retry";
      if (action.kind === "cancel_run") return "Cancel";
      return "Open";
    }

    async invokeContribution(contribution) {
      await this.withRunGuard(
        contribution.action,
        () => this.sendContribution(contribution)
      );
    }

    async sendContribution(contribution) {
      const requiredScope = contribution.action
        ? this.actionScope(contribution.action)
        : null;
      if (requiredScope && !this.hasScope(requiredScope)) {
        this.renderTransientError(
          `${requiredScope} is not granted. Use the permission action in the ghpr card.`
        );
        return;
      }
      try {
        const response = await this.bridge.request(
          "POST",
          `/api/v1/contributions/${encodeURIComponent(contribution.client_id)}/${encodeURIComponent(contribution.id)}/invoke?page_key=${encodeURIComponent(contribution.page_key)}`
        );
        this.openResponseURL(response);
        await this.refresh();
      } catch (error) {
        this.renderTransientError(error.message);
      }
    }

    async invokeAction(action, requiresConfirmation = false) {
      await this.withRunGuard(
        action,
        () => this.sendAction(action, requiresConfirmation)
      );
    }

    async sendAction(action, requiresConfirmation = false) {
      if (!this.page || !this.bridge.client) return;
      const requiredScope = this.actionScope(action);
      if (requiredScope && !this.hasScope(requiredScope)) {
        this.renderTransientError(
          `${requiredScope} is not granted. Use the permission action in the ghpr card.`
        );
        return;
      }
      if (requiresConfirmation && !this.window.confirm("Rerun failed GitHub jobs?")) return;
      try {
        const response = await this.bridge.request("POST", "/api/v1/actions", {
          action,
          page: this.page,
          confirmed: requiresConfirmation
        });
        this.openResponseURL(response);
        await this.refresh();
      } catch (error) {
        this.renderTransientError(error.message);
      }
    }

    openResponseURL(response) {
      if (!response?.url) return;
      if (/^https?:\/\//.test(response.url)) {
        this.gm.openInTab(response.url);
      } else {
        this.window.location.href = response.url;
      }
    }

    async openApp() {
      if (!this.page) this.page = parseGitHubPage(this.window.location);
      if (!this.page) return;
      if (!this.bridge.baseURL) await this.bridge.discover();
      if (!this.bridge.token) await this.bridge.authenticate();
      await this.invokeAction({ kind: "open_app" });
    }

    renderTransientError(message) {
      const root = this.document.getElementById(ROOT_ID);
      if (!root || !message) return;
      root.querySelector(".ghpr-error")?.remove();
      const error = createElement(this.document, "span", {
        className: "ghpr-error",
        text: message
      });
      root.append(error);
      this.window.setTimeout(() => error.remove(), 5000);
    }
  }

  function createGhprApp(options = {}) {
    const window = options.window || global.window || global;
    const document = options.document || window.document;
    const gm = options.gm || createGMAdapter(options.gmSource);
    return new GhprGitHubApp({ window, document, gm });
  }

  const exported = {
    BridgeClient,
    BridgeError,
    CLIENT,
    GhprGitHubApp,
    createElement,
    createGMAdapter,
    isVersionNewer,
    isConversationSurface,
    createGhprApp,
    parseGitHubPage,
    semanticTargets
  };
  global.GhprUserscript = exported;
  if (typeof module !== "undefined" && module.exports) module.exports = exported;

  if (!global.__GHPR_TEST__ && global.document) {
    createGhprApp().start().catch(() => {
      // Offline behavior is intentionally silent.
    });
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
