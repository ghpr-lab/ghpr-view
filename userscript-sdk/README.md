# @ghpr/userscript-sdk

The SDK connects third-party userscripts to the loopback-only ghpr Browser Bridge. Each client receives its own revocable capability token; the SDK never exposes GitHub credentials, agent credentials, workspace paths, raw repository reads, or shell execution.

```javascript
// Install through ghpr so this SDK is embedded; do not bind @require to a discovery port.
// @connect 127.0.0.1
// @connect localhost

const ghpr = await Ghpr.connect({
  id: "com.example.ci-helper",
  name: "Example CI Helper",
  version: "1.0.0",
  requestedScopes: ["pr:read", "analysis:read", "ui:contribute"],
  requiredScopes: []
});

const page = await ghpr.page.current();
await ghpr.ui.register({
  pageKey: page.key,
  ttlSeconds: 300,
  slot: "pr.header.actions",
  contribution: {
    id: "example-action",
    component: { type: "action", label: "Run Example Check", tone: "analysis" },
    action: { kind: "client_event", event: "example:clicked" }
  }
});
```

Available groups: `page`, `pr`, `ci`, `skills`, `analysis`, `tags`, `ui`, `events`, and `app`. Pairing is native and explicit; elevated scopes remain unapproved until the user selects them in ghpr-view.
