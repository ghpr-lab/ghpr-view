// ghpr Userscript SDK v1
(function (global) {
  "use strict";

  const DISCOVERY_PORTS = Array.from({ length: 10 }, (_, index) => 48120 + index);
  const PORT_KEY = "ghpr.sdk.bridge.port";
  const INSTANCE_KEY = "ghpr.sdk.bridge.instance";

  class GhprSDKError extends Error {
    constructor(message, status = 0, payload = null, code = null) {
      super(message);
      this.name = "GhprSDKError";
      this.status = status;
      this.payload = payload;
      this.code = code || payload?.error?.code || null;
    }
  }

  function createGMAdapter(source = global.GM || {}) {
    const legacy = global;
    const getValue = source.getValue || legacy.GM_getValue;
    const setValue = source.setValue || legacy.GM_setValue;
    const openInTab = source.openInTab || legacy.GM_openInTab;
    const xmlHttpRequest = source.xmlHttpRequest || legacy.GM_xmlhttpRequest;
    if (typeof xmlHttpRequest !== "function") {
      throw new GhprSDKError("GM.xmlHttpRequest is required.");
    }
    return {
      getValue: (key, fallback) => Promise.resolve(
        typeof getValue === "function" ? getValue.call(source, key, fallback) : fallback
      ),
      setValue: (key, value) => Promise.resolve(
        typeof setValue === "function" ? setValue.call(source, key, value) : undefined
      ),
      openInTab: (url) => {
        if (typeof openInTab === "function") {
          return openInTab.call(source, url, { active: true, insert: true });
        }
        return global.open(url, "_blank", "noopener");
      },
      request: (options) => new Promise((resolve, reject) => {
        const requestOptions = {
          ...options,
          onload: resolve,
          onerror: () => reject(new GhprSDKError("Browser Bridge request failed.")),
          ontimeout: () => reject(new GhprSDKError("Browser Bridge request timed out."))
        };
        try {
          const result = xmlHttpRequest.call(source, requestOptions);
          if (result && typeof result.then === "function") result.then(resolve, reject);
        } catch (error) {
          reject(error);
        }
      })
    };
  }

  function parseGitHubPage(locationLike = global.location) {
    const pathname = locationLike?.pathname || "/";
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
    match = pathname.match(/^\/([^/]+)\/([^/]+)\/actions\/runs\/(\d+)\/job\/(\d+)(?:\/|$)/);
    if (match) {
      const repository = `${decodeURIComponent(match[1])}/${decodeURIComponent(match[2])}`;
      const runID = Number(match[3]);
      const jobID = Number(match[4]);
      return {
        type: "workflow_run_job",
        key: `github:${repository.toLowerCase()}:run:${runID}:job:${jobID}`,
        repository,
        pr_number: null,
        workflow_run_id: runID,
        workflow_job_id: jobID
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

  function pageQuery(page) {
    const query = new URLSearchParams({ repository: page.repository });
    if (page.pr_number) query.set("number", String(page.pr_number));
    if (page.workflow_run_id) query.set("run_id", String(page.workflow_run_id));
    return query.toString();
  }

  const SUBJECT_TYPES = Object.freeze(["pull_request_revision", "workflow_job", "diff_line"]);

  function requireSubject(subject) {
    if (!subject || typeof subject !== "object" || Array.isArray(subject) || !SUBJECT_TYPES.includes(subject.type)) {
      throw new GhprSDKError(
        "A resolved GitHub subject (pull_request_revision, workflow_job, or diff_line) is required to start a v2 run.",
        0,
        null,
        "invalid_subject"
      );
    }
    return subject;
  }

  function requireSubjectKey(subjectKey) {
    if (typeof subjectKey !== "string" || subjectKey.length === 0) {
      throw new GhprSDKError("A subjectKey is required.", 0, null, "invalid_subject_key");
    }
    return subjectKey;
  }

  const CONTRACT_V2_API_VERSION = "ghpr.dev/browser/v2";

  const CONTRACT_V2_TARGET_KINDS = Object.freeze([
    "github.pull_request_revision",
    "github.workflow_job",
    "github.diff_line"
  ]);

  const CONTRACT_V2_SURFACES = Object.freeze([
    "github.pr.conversation.review-summary",
    "github.pr.checks.job.trailing",
    "github.pr.checks.job.insight",
    "github.actions.job.after-failure-summary",
    "github.pr.files.file.header",
    "github.pr.files.diff.line.after",
    "github.page.finding-drawer"
  ]);

  const CONTRACT_V2_VIEW_TYPES = Object.freeze([
    "job_verdict",
    "ci_insight",
    "review_summary",
    "review_finding_preview",
    "finding_count",
    "review_finding",
    "diff_snippet",
    "detail_drawer"
  ]);

  const CONTRACT_V2_ROOT_KEYS = Object.freeze(["api_version", "target_kinds", "placements"]);
  const CONTRACT_V2_PLACEMENT_KEYS = Object.freeze(["id", "surface", "bind_to", "repeat", "view"]);
  const CONTRACT_V2_REPEAT_KEYS = Object.freeze(["source"]);
  const CONTRACT_V2_VIEW_KEYS = Object.freeze(["type"]);
  const BIND_PATH_SEGMENT = /^[A-Za-z_][A-Za-z0-9_]*$/;

  function isPlainObject(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }

  function rejectUnknownContractKeys(object, allowed, where) {
    for (const key of Object.keys(object)) {
      if (!allowed.includes(key)) {
        throw new GhprSDKError(
          `Unknown browser contract field "${key}" in ${where}.`,
          0,
          null,
          "contract_unknown_field"
        );
      }
    }
  }

  function validateContractBindPath(path, prefix, where) {
    if (typeof path !== "string" || !path.startsWith(prefix)) {
      throw new GhprSDKError(
        `Invalid binding "${path}" in ${where}: must start with "${prefix}".`,
        0,
        null,
        "contract_invalid_binding"
      );
    }
    const segments = path.slice(prefix.length).split(".").filter(Boolean);
    if (segments.length === 0 || !segments.every((segment) => BIND_PATH_SEGMENT.test(segment))) {
      throw new GhprSDKError(
        `Invalid binding "${path}" in ${where}: every segment must match ${BIND_PATH_SEGMENT}.`,
        0,
        null,
        "contract_invalid_binding"
      );
    }
  }

  /**
   * Validates a Browser Contract v2 document against the strict PLAN.md allowlist:
   * only known root keys, target kinds, Surface IDs, view types, and dotted
   * `result.`/`item.` bindings are accepted. Any other field (selectors, CSS,
   * HTML, script/iframe/URL payloads, or unrecognized keys) is rejected because
   * it is simply absent from every allowlist below.
   */
  function validateBrowserContractV2(contract) {
    if (!isPlainObject(contract)) {
      throw new GhprSDKError("Browser contract v2 must be an object.", 0, null, "contract_invalid");
    }
    rejectUnknownContractKeys(contract, CONTRACT_V2_ROOT_KEYS, "contract root");
    if (contract.api_version !== CONTRACT_V2_API_VERSION) {
      throw new GhprSDKError(
        `Unsupported browser contract api_version "${contract.api_version}".`,
        0,
        null,
        "contract_unsupported_version"
      );
    }
    if (
      !Array.isArray(contract.target_kinds) ||
      contract.target_kinds.length === 0 ||
      !contract.target_kinds.every((kind) => CONTRACT_V2_TARGET_KINDS.includes(kind))
    ) {
      throw new GhprSDKError(
        "Browser contract target_kinds must be a non-empty array of known target kinds.",
        0,
        null,
        "contract_invalid_target_kind"
      );
    }
    if (!Array.isArray(contract.placements) || contract.placements.length === 0) {
      throw new GhprSDKError(
        "Browser contract placements must be a non-empty array.",
        0,
        null,
        "contract_invalid_placements"
      );
    }
    const seenIDs = new Set();
    const placements = contract.placements.map((placement, index) => {
      const where = `placements[${index}]`;
      if (!isPlainObject(placement)) {
        throw new GhprSDKError(`${where} must be an object.`, 0, null, "contract_invalid_placement");
      }
      rejectUnknownContractKeys(placement, CONTRACT_V2_PLACEMENT_KEYS, where);
      if (typeof placement.id !== "string" || placement.id.length === 0) {
        throw new GhprSDKError(`${where}.id must be a non-empty string.`, 0, null, "contract_invalid_placement");
      }
      if (seenIDs.has(placement.id)) {
        throw new GhprSDKError(`Duplicate placement id "${placement.id}".`, 0, null, "contract_duplicate_placement");
      }
      seenIDs.add(placement.id);
      if (!CONTRACT_V2_SURFACES.includes(placement.surface)) {
        throw new GhprSDKError(
          `${where}.surface "${placement.surface}" is not a known Surface ID.`,
          0,
          null,
          "contract_unknown_surface"
        );
      }
      if (!isPlainObject(placement.view)) {
        throw new GhprSDKError(`${where}.view must be an object.`, 0, null, "contract_invalid_view");
      }
      rejectUnknownContractKeys(placement.view, CONTRACT_V2_VIEW_KEYS, `${where}.view`);
      if (!CONTRACT_V2_VIEW_TYPES.includes(placement.view.type)) {
        throw new GhprSDKError(
          `${where}.view.type "${placement.view.type}" is not a known view type.`,
          0,
          null,
          "contract_unknown_view_type"
        );
      }
      let repeat = null;
      if (placement.repeat !== undefined) {
        if (!isPlainObject(placement.repeat)) {
          throw new GhprSDKError(`${where}.repeat must be an object.`, 0, null, "contract_invalid_repeat");
        }
        rejectUnknownContractKeys(placement.repeat, CONTRACT_V2_REPEAT_KEYS, `${where}.repeat`);
        validateContractBindPath(placement.repeat.source, "result.", `${where}.repeat.source`);
        repeat = Object.freeze({ source: placement.repeat.source });
      }
      if (placement.bind_to !== undefined) {
        validateContractBindPath(placement.bind_to, repeat ? "item." : "result.", `${where}.bind_to`);
      } else if (!repeat) {
        throw new GhprSDKError(`${where} must declare bind_to or repeat.`, 0, null, "contract_invalid_placement");
      }
      return Object.freeze({
        id: placement.id,
        surface: placement.surface,
        bindTo: placement.bind_to === undefined ? null : placement.bind_to,
        repeat,
        view: Object.freeze({ type: placement.view.type })
      });
    });
    return Object.freeze({
      apiVersion: contract.api_version,
      targetKinds: Object.freeze([...contract.target_kinds]),
      placements: Object.freeze(placements)
    });
  }

  class Transport {
    constructor(gm, descriptor) {
      this.gm = gm;
      this.descriptor = descriptor;
      this.baseURL = null;
      this.instanceID = null;
      this.token = null;
      this.client = null;
      this.tokenKey = `ghpr.sdk.${descriptor.id}.token`;
    }

    async discover() {
      const cached = Number(await this.gm.getValue(PORT_KEY, 0));
      const ports = cached
        ? [cached, ...DISCOVERY_PORTS.filter((port) => port !== cached)]
        : DISCOVERY_PORTS;
      for (const port of ports) {
        try {
          const baseURL = `http://127.0.0.1:${port}`;
          const discovery = await this.rawRequest(
            baseURL,
            "GET",
            "/.well-known/ghpr-browser-bridge",
            null,
            false
          );
          if (discovery.protocol !== "ghpr.browser-bridge/v1") continue;
          const priorInstance = await this.gm.getValue(INSTANCE_KEY, null);
          if (priorInstance && priorInstance !== discovery.instance_id) {
            await this.gm.setValue(this.tokenKey, null);
          }
          this.baseURL = baseURL;
          this.instanceID = discovery.instance_id;
          this.token = await this.gm.getValue(this.tokenKey, null);
          await this.gm.setValue(PORT_KEY, port);
          await this.gm.setValue(INSTANCE_KEY, discovery.instance_id);
          return discovery;
        } catch (_) {
          // Discovery is deliberately silent while probing closed ports.
        }
      }
      throw new GhprSDKError("ghpr Browser Bridge is offline.", 0, null, "bridge_offline");
    }

    async authenticate() {
      if (!this.token) return null;
      try {
        this.client = await this.request("GET", "/api/v1/client");
        return this.client;
      } catch (error) {
        if (error.status === 401) {
          this.token = null;
          this.client = null;
          await this.gm.setValue(this.tokenKey, null);
          return null;
        }
        throw error;
      }
    }

    async pair({ onState, pollIntervalMs = 1000, timeoutMs = 300000 } = {}) {
      onState?.("requesting");
      const pairing = await this.request(
        "POST",
        "/api/v1/pairings",
        this.descriptor,
        false
      );
      this.gm.openInTab(pairing.pairing_url);
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (pollIntervalMs > 0) {
          await new Promise((resolve) => global.setTimeout(resolve, pollIntervalMs));
        }
        const status = await this.request(
          "GET",
          `/api/v1/pairings/${encodeURIComponent(pairing.request_id)}?secret=${encodeURIComponent(pairing.pairing_secret)}`,
          null,
          false
        );
        onState?.(status.state);
        if (status.state === "approved" && status.token) {
          this.token = status.token;
          this.client = status.client;
          await this.gm.setValue(this.tokenKey, status.token);
          return status.client;
        }
        if (["denied", "expired"].includes(status.state)) {
          throw new GhprSDKError(
            `Pairing was ${status.state}.`,
            403,
            status,
            `pairing_${status.state}`
          );
        }
      }
      throw new GhprSDKError("Pairing approval timed out.", 408, null, "pairing_timeout");
    }

    async request(method, path, body = null, authenticated = true) {
      if (!this.baseURL) {
        throw new GhprSDKError("ghpr Browser Bridge is offline.", 0, null, "bridge_offline");
      }
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
        throw new GhprSDKError(
          "Browser Bridge returned invalid JSON.",
          response.status,
          null,
          "invalid_json"
        );
      }
      if (response.status < 200 || response.status >= 300) {
        throw new GhprSDKError(
          payload?.error?.message || `Browser Bridge returned ${response.status}.`,
          response.status,
          payload
        );
      }
      return payload;
    }
  }

  class GhprClient {
    constructor(transport, page) {
      this.transport = transport;
      this.pageContext = page;
      this.client = transport.client;
      this.page = Object.freeze({ current: async () => this.pageContext });
      this.pr = Object.freeze({
        get: async (pageContext = this.requirePage()) => {
          const snapshot = await this.transport.request(
            "GET",
            `/api/v1/page?${pageQuery(pageContext)}`
          );
          return snapshot.pull_request;
        }
      });
      this.ci = Object.freeze({
        listRuns: async (pageContext = this.requirePage()) => {
          const pullRequest = await this.pr.get(pageContext);
          return pullRequest?.ci_workflows || [];
        },
        listFailedJobs: async (pageContext = this.requirePage()) => {
          const runs = await this.ci.listRuns(pageContext);
          return runs.filter((run) => Number(run.failure_count || 0) > 0);
        }
      });
      this.skills = Object.freeze({
        list: async () => {
          const response = await this.transport.request("GET", "/api/v1/skills");
          return response.skills;
        },
        run: async (skillID, pageContext = this.requirePage()) => this.transport.request(
          "POST",
          "/api/v1/runs",
          { skill_id: skillID, page: pageContext }
        ),
        cancel: async (runID) => this.transport.request(
          "POST",
          `/api/v1/runs/${encodeURIComponent(runID)}/cancel`
        ),
        retry: async (runID) => this.transport.request(
          "POST",
          `/api/v1/runs/${encodeURIComponent(runID)}/retry`
        )
      });
      this.subjects = Object.freeze({
        resolve: async (input) => this.transport.request(
          "POST",
          "/api/v1/subjects/resolve",
          input
        )
      });
      this.runs = Object.freeze({
        start: async (skillID, subject) => this.transport.request(
          "POST",
          "/api/v1/runs",
          { skill_id: skillID, subject: requireSubject(subject) }
        ),
        cancel: async (runID) => this.transport.request(
          "POST",
          `/api/v1/runs/${encodeURIComponent(runID)}/cancel`
        ),
        retry: async (runID) => this.transport.request(
          "POST",
          `/api/v1/runs/${encodeURIComponent(runID)}/retry`
        )
      });
      this.findings = Object.freeze({
        list: async (subjectKey) => {
          const response = await this.transport.request(
            "GET",
            `/api/v1/findings?subject_key=${encodeURIComponent(requireSubjectKey(subjectKey))}`
          );
          return response.findings;
        },
        get: async (findingID) => this.transport.request(
          "GET",
          `/api/v1/findings/${encodeURIComponent(findingID)}`
        ),
        dismiss: async (findingID) => this.transport.request(
          "POST",
          `/api/v1/findings/${encodeURIComponent(findingID)}/dismiss`
        )
      });
      this.analysis = Object.freeze({
        list: async (pageKey = this.requirePage().key) => {
          const response = await this.transport.request(
            "GET",
            `/api/v1/analyses?page_key=${encodeURIComponent(pageKey)}`
          );
          return response.analyses;
        },
        get: async (analysisID) => this.transport.request(
          "GET",
          `/api/v1/analyses/${encodeURIComponent(analysisID)}`
        ),
        openDetail: async (analysisID) => {
          const response = await this.transport.request(
            "POST",
            `/api/v1/analyses/${encodeURIComponent(analysisID)}/open-detail`
          );
          this.transport.gm.openInTab(response.url);
          return response.url;
        }
      });
      this.tags = Object.freeze({
        list: async (pageKey = this.requirePage().key) => {
          const response = await this.transport.request(
            "GET",
            `/api/v1/tags?page_key=${encodeURIComponent(pageKey)}`
          );
          return response.tags;
        },
        set: async (tag, pageKey = this.requirePage().key) => {
          const response = await this.transport.request(
            "PUT",
            "/api/v1/tags",
            { page_key: pageKey, tag }
          );
          return response.tags;
        },
        remove: async (tag, pageKey = this.requirePage().key) => {
          const response = await this.transport.request(
            "DELETE",
            "/api/v1/tags",
            { page_key: pageKey, tag }
          );
          return response.tags;
        }
      });
      this.ui = Object.freeze({
        register: async (registration) => this.transport.request(
          "POST",
          "/api/v1/contributions",
          {
            page_key: registration.pageKey || registration.page_key || this.requirePage().key,
            ttl_seconds: registration.ttlSeconds || registration.ttl_seconds || 300,
            slot: registration.slot,
            contribution: registration.contribution
          }
        ),
        unregister: async (contributionID) => this.transport.request(
          "DELETE",
          `/api/v1/contributions/${encodeURIComponent(contributionID)}`
        )
      });
      this.events = Object.freeze({
        poll: async (cursor = 0) => this.transport.request(
          "GET",
          `/api/v1/events?cursor=${encodeURIComponent(cursor)}`
        ),
        subscribe: (handler, options = {}) => this.subscribe(handler, options)
      });
      this.app = Object.freeze({
        open: async (pageContext = this.requirePage()) => this.action(
          { kind: "open_app" },
          pageContext
        ),
        showPR: async (pageContext = this.requirePage()) => this.action(
          { kind: "show_pr" },
          pageContext
        )
      });
    }

    requirePage() {
      if (!this.pageContext) {
        throw new GhprSDKError(
          "The current page is not a supported GitHub PR or workflow page.",
          0,
          null,
          "unsupported_page"
        );
      }
      return this.pageContext;
    }

    action(action, page = this.requirePage(), confirmed = false) {
      return this.transport.request(
        "POST",
        "/api/v1/actions",
        { page, action, confirmed }
      );
    }

    subscribe(handler, { cursor = 0, intervalMs = 2000 } = {}) {
      let stopped = false;
      let currentCursor = cursor;
      const poll = async () => {
        while (!stopped) {
          const response = await this.events.poll(currentCursor);
          currentCursor = response.cursor;
          for (const event of response.events) await handler(event);
          if (!stopped) {
            await new Promise((resolve) => global.setTimeout(resolve, intervalMs));
          }
        }
      };
      const done = poll();
      return Object.freeze({
        stop: () => { stopped = true; },
        done
      });
    }
  }

  const Ghpr = Object.freeze({
    async connect(options) {
      if (!options?.id || !options?.name || !options?.version) {
        throw new GhprSDKError("id, name, and version are required.", 0, null, "invalid_client");
      }
      const descriptor = {
        id: options.id,
        name: options.name,
        version: options.version,
        requested_scopes: options.requestedScopes || options.requested_scopes || [],
        required_scopes: options.requiredScopes || options.required_scopes || []
      };
      const transport = new Transport(createGMAdapter(options.gm), descriptor);
      await transport.discover();
      let client = await transport.authenticate();
      if (!client) {
        if (options.pair === false) {
          throw new GhprSDKError(
            "Browser client approval is required.",
            401,
            null,
            "pairing_required"
          );
        }
        client = await transport.pair({
          onState: options.onPairingState,
          pollIntervalMs: options.pairingPollIntervalMs,
          timeoutMs: options.pairingTimeoutMs
        });
      }
      const result = new GhprClient(
        transport,
        options.page || parseGitHubPage(options.location || global.location)
      );
      result.client = client;
      return result;
    },
    parseGitHubPage,
    validateBrowserContractV2,
    Error: GhprSDKError,
    version: "1.0.0"
  });

  global.Ghpr = Ghpr;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = {
      Ghpr,
      GhprSDKError,
      createGMAdapter,
      parseGitHubPage,
      validateBrowserContractV2,
      SUBJECT_TYPES,
      CONTRACT_V2_TARGET_KINDS,
      CONTRACT_V2_SURFACES,
      CONTRACT_V2_VIEW_TYPES
    };
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
