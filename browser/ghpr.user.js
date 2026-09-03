// ==UserScript==
// @name         ghpr for GitHub
// @namespace    https://github.com/xiaocang/ghpr-view
// @version      2.0.13
// @description  Run local ghpr Skills and render their results on GitHub pull requests.
// @match        https://github.com/*/*/pull/*
// @match        https://github.com/*/*/actions/runs/*
// @grant        GM.xmlHttpRequest
// @grant        GM.openInTab
// @grant        GM.registerMenuCommand
// @grant        GM.getValue
// @grant        GM.setValue
// @grant        GM.setClipboard
// @connect      localhost
// @connect      127.0.0.1
// @run-at       document-idle
// ==/UserScript==

// >>> BEGIN GENERATED: browser/surface-renderers.js (via `npm run build:userscript` in browser/) — do not edit inline, edit the source file instead
// browser/surface-renderers.js
//
// Pure DOM renderer + style registry shared by the GitHub userscript v2 path
// and the Skill Workbench preview. No Bridge/network access, no GitHub-page
// queries, no globals besides the `document` passed in. Every render*
// function takes (document, model) and returns a detached DOM element built
// only from `model`.
//
// Also exports the keyed mounting primitives (SurfaceMount, InlinePanelHost,
// DrawerHost, SurfaceRegistry) used to place that DOM into a host page
// without destroying/rebuilding native GitHub nodes.

(function ghprSurfaceRenderersModule(global) {
  "use strict";

  const SURFACE_IDS = Object.freeze({
    conversationReviewSummary: "github.pr.conversation.review-summary",
    checksJobTrailing: "github.pr.checks.job.trailing",
    checksJobInsight: "github.pr.checks.job.insight",
    actionsJobAfterFailureSummary: "github.actions.job.after-failure-summary",
    filesFileHeader: "github.pr.files.file.header",
    filesDiffLineAfter: "github.pr.files.diff.line.after",
    pageFindingDrawer: "github.page.finding-drawer"
  });

  const VIEW_TYPES = Object.freeze([
    "job_verdict",
    "ci_insight",
    "review_summary",
    "review_finding_preview",
    "finding_count",
    "review_finding",
    "diff_snippet",
    "detail_drawer"
  ]);

  const SURFACE_STYLE_ID = "ghpr-surface-styles";

  const SURFACE_STYLE_TEXT = `
    .ghpr-surface {
      box-sizing: border-box;
      color: var(--fgColor-default, #1f2328);
      font: 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      line-height: 1.5;
    }
    .ghpr-surface *, .ghpr-surface *::before, .ghpr-surface *::after { box-sizing: border-box; }
    .ghpr-surface a { color: var(--fgColor-accent, #0969da); }
    .ghpr-surface button { font: inherit; }
    .ghpr-beta-pill {
      background: var(--bgColor-accent-muted, #ddf4ff);
      border: 1px solid var(--borderColor-accent-muted, #54aeff66);
      border-radius: 999px;
      color: var(--fgColor-accent, #0969da);
      display: inline-flex;
      font-size: 9px;
      font-weight: 600;
      line-height: 16px;
      padding: 0 6px;
      vertical-align: middle;
    }
    .ghpr-severity {
      align-items: center;
      display: inline-flex;
      flex: 0 0 auto;
      gap: 4px;
      font-size: 11px;
      font-weight: 600;
    }
    .ghpr-severity-icon { flex: 0 0 auto; }
    .ghpr-severity[data-severity="error"] { color: var(--fgColor-danger, #d1242f); }
    .ghpr-severity[data-severity="warning"] { color: var(--fgColor-attention, #9a6700); }
    .ghpr-severity[data-severity="info"] { color: var(--fgColor-accent, #0969da); }
    .ghpr-action-button {
      align-items: center;
      appearance: none;
      background: var(--button-default-bgColor-rest, var(--bgColor-default, #f6f8fa));
      border: 1px solid var(--button-default-borderColor-rest, var(--borderColor-default, #d1d9e0));
      border-radius: 6px;
      color: var(--button-default-fgColor-rest, var(--fgColor-default, #1f2328));
      cursor: pointer;
      display: inline-flex;
      font-weight: 500;
      gap: 5px;
      justify-content: center;
      min-height: 28px;
      padding: 3px 10px;
      white-space: nowrap;
    }
    .ghpr-action-button:hover { background: var(--button-default-bgColor-hover, var(--bgColor-neutral-muted, #eaeef2)); }
    .ghpr-action-button:focus-visible,
    .ghpr-finding-count-pill:focus-visible,
    .ghpr-review-finding-preview:focus-visible,
    .ghpr-ci-tab:focus-visible {
      outline: 2px solid var(--focus-outlineColor, #0969da);
      outline-offset: 2px;
    }
    .ghpr-action-button[data-primary="true"] {
      background: var(--button-primary-bgColor-rest, var(--bgColor-accent-emphasis, #1f883d));
      border-color: var(--button-primary-borderColor-rest, var(--bgColor-accent-emphasis, #1f883d));
      color: var(--button-primary-fgColor-rest, var(--fgColor-onEmphasis, #fff));
    }
    .ghpr-action-button[data-copy-state="copied"] {
      border-color: var(--borderColor-success-emphasis, #1a7f37);
      color: var(--fgColor-success, #1a7f37);
    }
    .ghpr-action-button[data-copy-state="failed"] {
      border-color: var(--borderColor-danger-emphasis, #cf222e);
      color: var(--fgColor-danger, #d1242f);
    }
    .ghpr-job-verdict {
      align-items: center;
      display: inline-flex;
      gap: 12px;
      margin-left: auto;
      min-width: min(100%, 260px);
      padding-left: 12px;
    }
    .ghpr-job-verdict-copy {
      color: var(--fgColor-default, #1f2328);
      font-size: 12px;
      margin-left: auto;
      white-space: nowrap;
    }
    .ghpr-job-verdict[data-status="likely_flaky"] .ghpr-job-verdict-copy { color: var(--fgColor-attention, #9a6700); }
    .ghpr-job-verdict[data-status="likely_related"] .ghpr-job-verdict-copy,
    .ghpr-job-verdict[data-status="failed"] .ghpr-job-verdict-copy { color: var(--fgColor-danger, #d1242f); }
    .ghpr-job-verdict[data-status="queued"] .ghpr-job-verdict-copy,
    .ghpr-job-verdict[data-status="running"] .ghpr-job-verdict-copy { color: var(--fgColor-muted, #656d76); }
    .ghpr-ci-insight {
      background: var(--bgColor-default, #fff);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      margin: 8px 0;
      overflow: hidden;
    }
    .ghpr-ci-insight-header {
      align-items: center;
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      gap: 7px;
      min-height: 42px;
      padding: 9px 14px;
    }
    .ghpr-ci-insight-title { font-size: 13px; font-weight: 600; }
    .ghpr-ci-insight-body {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(180px, 220px);
    }
    .ghpr-ci-insight-copy { padding: 14px 18px 16px; }
    .ghpr-ci-insight-narrative { margin-top: 14px; }
    .ghpr-ci-insight-narrative:first-child { margin-top: 0; }
    .ghpr-ci-insight-narrative h4 {
      font-size: 12px;
      font-weight: 600;
      margin: 0 0 3px;
    }
    .ghpr-ci-insight-narrative p { margin: 0; }
    .ghpr-ci-insight-list { margin: 4px 0 0 18px; padding: 0; }
    .ghpr-ci-insight-unavailable { color: var(--fgColor-muted, #656d76); }
    .ghpr-ci-result-rail {
      background: var(--bgColor-muted, #f6f8fa);
      border-left: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      flex-direction: column;
      gap: 10px;
      padding: 14px;
    }
    .ghpr-ci-result-card {
      background: var(--bgColor-default, #fff);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      overflow: hidden;
    }
    .ghpr-ci-result-card-head {
      align-items: center;
      display: flex;
      font-weight: 600;
      gap: 7px;
      padding: 9px 10px;
    }
    .ghpr-ci-result-card[data-status="ready"] .ghpr-ci-result-card-head {
      background: var(--bgColor-success-muted, #dafbe1);
    }
    .ghpr-ci-result-card-status {
      color: var(--fgColor-success, #1a7f37);
      font-size: 13px;
    }
    .ghpr-ci-result-card[data-status="running"] .ghpr-ci-result-card-status,
    .ghpr-ci-result-card[data-status="unavailable"] .ghpr-ci-result-card-status {
      color: var(--fgColor-attention, #9a6700);
    }
    .ghpr-ci-result-card-actions {
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      flex-direction: column;
    }
    .ghpr-ci-result-card-actions .ghpr-action-button {
      background: transparent;
      border: 0;
      border-radius: 0;
      justify-content: flex-start;
      min-height: 32px;
      padding: 6px 10px;
    }
    .ghpr-ci-tabs {
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      gap: 18px;
      padding: 0 14px;
    }
    .ghpr-ci-tab {
      appearance: none;
      background: transparent;
      border: 0;
      border-bottom: 2px solid transparent;
      color: var(--fgColor-muted, #656d76);
      cursor: pointer;
      padding: 9px 0 7px;
    }
    .ghpr-ci-tab[aria-selected="true"] {
      border-bottom-color: var(--underlineNav-borderColor-active, #fd8c73);
      color: var(--fgColor-default, #1f2328);
      font-weight: 600;
    }
    .ghpr-ci-actions-content { min-height: 92px; padding: 14px 16px; }
    .ghpr-ci-actions-footer {
      align-items: center;
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      gap: 8px;
      justify-content: flex-end;
      flex-wrap: wrap;
      padding: 8px 12px;
    }
    .ghpr-review-summary {
      background: var(--bgColor-default, #fff);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      margin: 12px 0;
      overflow: hidden;
    }
    .ghpr-review-summary-identity {
      align-items: center;
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      gap: 7px;
      min-height: 38px;
      padding: 7px 12px;
    }
    .ghpr-review-summary-avatar {
      align-items: center;
      background: var(--bgColor-neutral-emphasis, #57606a);
      border-radius: 50%;
      color: var(--fgColor-onEmphasis, #fff);
      display: inline-flex;
      font-size: 10px;
      font-weight: 700;
      height: 24px;
      justify-content: center;
      width: 24px;
    }
    .ghpr-review-summary-bot {
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 999px;
      color: var(--fgColor-muted, #656d76);
      font-size: 9px;
      line-height: 14px;
      padding: 0 5px;
    }
    .ghpr-review-summary-time { color: var(--fgColor-muted, #656d76); }
    .ghpr-review-summary-toolbar {
      align-items: center;
      display: flex;
      gap: 8px;
      justify-content: space-between;
      padding: 10px 12px 4px;
    }
    .ghpr-review-summary-title {
      align-items: center;
      display: flex;
      font-size: 13px;
      gap: 7px;
    }
    .ghpr-review-summary-meta {
      color: var(--fgColor-muted, #656d76);
      display: flex;
      gap: 10px;
      justify-content: space-between;
      padding: 0 12px 9px;
    }
    .ghpr-review-summary-findings { border-top: 1px solid var(--borderColor-muted, #d8dee4); }
    .ghpr-review-finding {
      padding: 10px 12px;
    }
    .ghpr-review-summary-findings > .ghpr-review-finding,
    .ghpr-review-summary-findings > .ghpr-review-finding-preview {
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
    }
    .ghpr-review-summary-findings > :first-child { border-top: 0; }
    .ghpr-review-finding-head {
      align-items: center;
      display: flex;
      gap: 8px;
    }
    .ghpr-review-finding-title {
      flex: 1 1 auto;
      font-weight: 600;
      min-width: 0;
    }
    .ghpr-review-finding-confidence {
      color: var(--fgColor-muted, #656d76);
      flex: 0 0 auto;
      font-size: 11px;
    }
    .ghpr-lifecycle-chip {
      border: 1px solid var(--borderColor-attention-muted, #d4a72c66);
      border-radius: 999px;
      color: var(--fgColor-attention, #9a6700);
      flex: 0 0 auto;
      justify-self: start;
      font-size: 9px;
      font-weight: 600;
      letter-spacing: .02em;
      line-height: 16px;
      padding: 0 6px;
      text-transform: uppercase;
      white-space: nowrap;
    }
    .ghpr-lifecycle-chip[data-tone="danger"] {
      border-color: var(--borderColor-danger-muted, #ff818266);
      color: var(--fgColor-danger, #d1242f);
    }
    .ghpr-review-finding-location {
      color: var(--fgColor-muted, #656d76);
      font: 10px ui-monospace, "SFMono-Regular", Consolas, monospace;
      margin-top: 2px;
    }
    .ghpr-review-finding-body { margin-top: 7px; }
    .ghpr-review-finding-body p { margin: 5px 0; }
    .ghpr-review-finding-preview {
      align-items: center;
      cursor: pointer;
      display: grid;
      gap: 3px 8px;
      grid-template-columns: auto minmax(0, 1fr) auto auto auto;
      padding: 8px 12px;
    }
    .ghpr-review-finding-preview-location { grid-column: 2 / 4; }
    .ghpr-review-finding-preview-chevron {
      color: var(--fgColor-muted, #656d76);
      grid-column: 5;
      grid-row: 1 / span 2;
      transition: transform .1s ease;
    }
    .ghpr-review-finding-preview > .ghpr-finding-copy {
      grid-column: 4;
      grid-row: 1 / span 2;
    }
    .ghpr-finding-copy {
      align-self: center;
      appearance: none;
      background: transparent;
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      color: var(--fgColor-muted, #656d76);
      cursor: pointer;
      font-size: 10px;
      line-height: 18px;
      padding: 0 6px;
      white-space: nowrap;
    }
    .ghpr-finding-copy:hover { background: var(--bgColor-neutral-muted, #eaeef2); }
    .ghpr-finding-copy:focus-visible {
      outline: 2px solid var(--focus-outlineColor, #0969da);
      outline-offset: 2px;
    }
    .ghpr-finding-copy[data-copy-state="copied"] {
      border-color: var(--borderColor-success-emphasis, #1a7f37);
      color: var(--fgColor-success, #1a7f37);
    }
    .ghpr-finding-copy[data-copy-state="failed"] {
      border-color: var(--borderColor-danger-emphasis, #cf222e);
      color: var(--fgColor-danger, #d1242f);
    }
    .ghpr-review-finding-preview[data-expanded="true"] .ghpr-review-finding-preview-chevron { transform: rotate(90deg); }
    .ghpr-review-finding-preview[data-inline="true"] {
      background: var(--bgColor-default, #fff);
      border: 1px solid var(--borderColor-muted, #d8dee4);
      border-left: 3px solid var(--fgColor-accent, #0969da);
      border-radius: 6px;
      margin: 6px 0 4px;
      max-width: 760px;
      padding: 7px 10px;
      white-space: normal;
    }
    .ghpr-review-finding-preview[data-inline="true"][data-severity="warning"] {
      border-left-color: var(--fgColor-attention, #9a6700);
    }
    .ghpr-review-finding-preview[data-inline="true"][data-severity="error"] {
      border-left-color: var(--fgColor-danger, #d1242f);
    }
    .ghpr-review-finding-preview[data-inline="true"][data-expanded="true"] {
      background: var(--bgColor-accent-muted, #ddf4ff);
    }
    .ghpr-review-finding-preview[data-inline="true"] .ghpr-review-finding-preview-chevron,
    .ghpr-review-finding-preview[data-inline="true"] > .ghpr-finding-copy {
      grid-row: 1 / -1;
    }
    .ghpr-finding-scope-chip {
      background: var(--bgColor-neutral-muted, #eaeef2);
      border-radius: 4px;
      color: var(--fgColor-muted, #656d76);
      flex: 0 0 auto;
      justify-self: start;
      font-size: 9px;
      font-weight: 600;
      letter-spacing: .02em;
      line-height: 16px;
      padding: 0 6px;
      text-transform: uppercase;
      white-space: nowrap;
    }
    /* File-scope findings are a band across the file, not a card on one row. */
    .ghpr-review-finding-preview[data-file-level="true"] {
      background: var(--bgColor-inset, #f6f8fa);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      margin: 8px 0;
      padding: 8px 12px;
      white-space: normal;
    }
    .ghpr-review-finding-preview[data-file-level="true"] .ghpr-review-finding-preview-chevron,
    .ghpr-review-finding-preview[data-file-level="true"] > .ghpr-finding-copy {
      grid-row: 1 / -1;
    }
    [data-ghpr-surface="github.pr.files.file.header"].ghpr-review-finding {
      background: var(--bgColor-inset, #f6f8fa);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      margin: 8px 0;
    }
    .ghpr-review-finding-preview-summary {
      -webkit-box-orient: vertical;
      -webkit-line-clamp: 2;
      color: var(--fgColor-muted, #656d76);
      display: -webkit-box;
      grid-column: 1 / -1;
      margin: 0;
      overflow: hidden;
    }
    .ghpr-review-finding-preview > .ghpr-diff-snippet {
      grid-column: 1 / -1;
      margin-left: 20px;
      width: calc(100% - 20px);
    }
    .ghpr-diff-snippet {
      background: var(--bgColor-inset, #f6f8fa);
      border: 1px solid var(--borderColor-muted, #d8dee4);
      border-radius: 4px;
      font: 10px/1.5 ui-monospace, "SFMono-Regular", Consolas, monospace;
      margin: 7px 0 0;
      overflow: auto;
      padding: 3px 0;
      white-space: pre;
    }
    .ghpr-diff-snippet-line { min-height: 16px; padding: 0 8px; }
    .ghpr-diff-snippet-line[data-kind="added"] { background: var(--bgColor-success-muted, #dafbe1); }
    .ghpr-diff-snippet-line[data-kind="removed"] { background: var(--bgColor-danger-muted, #ffebe9); }
    .ghpr-diff-snippet-line[data-kind="ellipsis"] { color: var(--fgColor-muted, #656d76); }
    .ghpr-finding-count-pill {
      appearance: none;
      background: var(--bgColor-attention-muted, #fff8c5);
      border: 1px solid var(--borderColor-attention-muted, #d4a72c66);
      border-radius: 999px;
      color: var(--fgColor-attention, #9a6700);
      cursor: pointer;
      font-size: 10px;
      font-weight: 500;
      line-height: 18px;
      padding: 0 7px;
      white-space: nowrap;
    }
    .ghpr-inline-finding-row > td {
      background: var(--bgColor-default, #fff);
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
      padding: 0;
    }
    .ghpr-inline-finding-card { padding: 12px 14px; }
    .ghpr-finding-tools {
      align-items: center;
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 9px;
    }
    .ghpr-operation-card-host {
      color: var(--fgColor-default, #1f2328);
    }
    .ghpr-operation-card-host.ghpr-operation-card-sidebar {
      margin: 0 0 16px;
      padding: 0;
    }
    .ghpr-operation-card-host.ghpr-operation-card-floating {
      bottom: 16px;
      position: fixed;
      right: 16px;
      width: min(280px, calc(100vw - 32px));
      z-index: 30;
    }
    .ghpr-operation-card-host.ghpr-operation-card-floating.ghpr-operation-card-collapsed {
      max-width: calc(100vw - 32px);
      min-width: 156px;
      width: auto;
    }
    .ghpr-operation-card {
      background: var(--bgColor-default, #fff);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 8px;
      box-shadow: var(--shadow-resting-small, 0 1px 2px rgba(31, 35, 40, .06));
      overflow: visible;
      position: relative;
    }
    .ghpr-operation-card::before {
      background: var(--bgColor-accent-emphasis, #0969da);
      content: "";
      inset: 0 auto 0 0;
      position: absolute;
      width: 3px;
    }
    .ghpr-operation-card[data-state="running"]::before {
      background: var(--bgColor-attention-emphasis, #bf8700);
    }
    .ghpr-operation-card[data-state="attention"]::before {
      background: var(--bgColor-danger-emphasis, #cf222e);
    }
    .ghpr-operation-card-head {
      align-items: center;
      display: flex;
      gap: 7px;
      min-height: 38px;
      padding: 8px 10px 7px 13px;
    }
    .ghpr-operation-card-mark {
      align-items: center;
      background: var(--bgColor-neutral-muted, #afb8c133);
      border-radius: 5px;
      display: inline-flex;
      font: 700 10px/1 ui-monospace, "SFMono-Regular", Consolas, monospace;
      height: 22px;
      justify-content: center;
      letter-spacing: -.5px;
      width: 22px;
    }
    .ghpr-operation-card-title {
      font-size: 13px;
      font-weight: 600;
    }
    .ghpr-operation-card-status {
      color: var(--fgColor-muted, #656d76);
      font-size: 11px;
      margin-left: auto;
      white-space: nowrap;
    }
    .ghpr-operation-card-update {
      appearance: none;
      background: transparent;
      border: 0;
      color: var(--fgColor-accent, #0969da);
      cursor: pointer;
      font: inherit;
      padding: 2px;
    }
    .ghpr-operation-card-toggle {
      align-items: center;
      appearance: none;
      background: transparent;
      border: 0;
      border-radius: 4px;
      color: var(--fgColor-muted, #656d76);
      cursor: pointer;
      display: inline-flex;
      font-size: 14px;
      height: 24px;
      justify-content: center;
      padding: 0;
      width: 24px;
    }
    .ghpr-operation-card-toggle:hover {
      background: var(--button-default-bgColor-hover, var(--bgColor-neutral-muted, #eaeef2));
      color: var(--fgColor-default, #1f2328);
    }
    .ghpr-operation-card[data-collapsed="true"] .ghpr-operation-card-body {
      display: none;
    }
    .ghpr-operation-card-body {
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
      padding: 9px 10px 10px 13px;
    }
    .ghpr-operation-card-summary {
      color: var(--fgColor-muted, #656d76);
      margin: 0 0 8px;
    }
    .ghpr-operation-card-signals {
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
      margin: 0 0 9px;
    }
    .ghpr-operation-card-signal {
      background: var(--bgColor-neutral-muted, #afb8c133);
      border-radius: 999px;
      color: var(--fgColor-muted, #656d76);
      font-size: 10px;
      line-height: 18px;
      padding: 0 7px;
    }
    .ghpr-operation-card-signal[data-tone="danger"] {
      background: var(--bgColor-danger-muted, #ffebe9);
      color: var(--fgColor-danger, #d1242f);
    }
    .ghpr-operation-card-signal[data-tone="agent"] {
      background: var(--bgColor-done-muted, #fbefff);
      color: var(--fgColor-done, #8250df);
    }
    .ghpr-operation-progress {
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      margin: 0 0 9px;
      overflow: hidden;
    }
    .ghpr-operation-progress > summary {
      align-items: center;
      background: var(--bgColor-muted, #f6f8fa);
      cursor: pointer;
      display: flex;
      font-size: 11px;
      font-weight: 600;
      gap: 8px;
      list-style: none;
      min-height: 30px;
      padding: 6px 8px;
    }
    .ghpr-operation-progress > summary::-webkit-details-marker { display: none; }
    .ghpr-operation-progress > summary::before {
      color: var(--fgColor-muted, #656d76);
      content: "›";
      font-size: 14px;
      line-height: 1;
    }
    .ghpr-operation-progress[open] > summary::before { transform: rotate(90deg); }
    .ghpr-operation-progress-state {
      color: var(--fgColor-muted, #656d76);
      font-family: ui-monospace, "SFMono-Regular", Consolas, monospace;
      font-size: 10px;
      font-weight: 400;
      margin-left: auto;
      max-width: 65%;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .ghpr-operation-progress-steps {
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
    }
    .ghpr-operation-progress-step + .ghpr-operation-progress-step {
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
    }
    .ghpr-operation-progress-step > summary {
      align-items: center;
      background: var(--bgColor-muted, #f6f8fa);
      cursor: pointer;
      display: grid;
      font-size: 11px;
      font-weight: 600;
      gap: 7px;
      grid-template-columns: 14px minmax(0, 1fr) auto;
      list-style: none;
      min-height: 32px;
      padding: 7px 8px;
    }
    .ghpr-operation-progress-step > summary::-webkit-details-marker { display: none; }
    .ghpr-operation-progress-step[open] > summary {
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
    }
    .ghpr-operation-progress-step-marker {
      color: var(--fgColor-accent, #0969da);
      text-align: center;
    }
    .ghpr-operation-progress-step[data-status="success"] .ghpr-operation-progress-step-marker {
      color: var(--fgColor-success, #1a7f37);
    }
    .ghpr-operation-progress-step-meta {
      color: var(--fgColor-muted, #656d76);
      font-size: 10px;
      font-variant-numeric: tabular-nums;
      font-weight: 400;
    }
    .ghpr-operation-progress-log {
      background: var(--bgColor-inset, var(--bgColor-muted, #f6f8fa));
      color: var(--fgColor-default, #1f2328);
      font: 11px/1.5 ui-monospace, "SFMono-Regular", Consolas, monospace;
      max-height: 220px;
      overflow: auto;
      overscroll-behavior: contain;
    }
    .ghpr-operation-progress-line {
      align-items: baseline;
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
      display: grid;
      gap: 7px;
      grid-template-columns: 24px 12px minmax(0, 1fr);
      padding: 6px 8px;
    }
    .ghpr-operation-progress-line:last-child { border-bottom: 0; }
    .ghpr-operation-progress-line-number {
      color: var(--fgColor-muted, #656d76);
      font-variant-numeric: tabular-nums;
      text-align: right;
    }
    .ghpr-operation-progress-line code {
      color: inherit;
      min-width: 0;
      overflow-wrap: anywhere;
      white-space: pre-wrap;
    }
    .ghpr-operation-progress-marker { color: var(--fgColor-accent, #0969da); text-align: center; }
    .ghpr-operation-progress-line[data-kind="success"] .ghpr-operation-progress-marker { color: var(--fgColor-success, #1a7f37); }
    .ghpr-operation-progress-line[data-kind="warning"] .ghpr-operation-progress-marker { color: var(--fgColor-attention, #9a6700); }
    .ghpr-operation-progress-line[data-kind="error"] .ghpr-operation-progress-marker { color: var(--fgColor-danger, #d1242f); }
    .ghpr-item-navigator {
      align-items: center;
      display: flex;
      gap: 6px;
    }
    .ghpr-item-navigator .ghpr-action-button { min-height: 26px; padding: 2px 8px; }
    .ghpr-item-navigator-count {
      color: var(--fgColor-muted, #656d76);
      font-size: 11px;
      font-variant-numeric: tabular-nums;
      text-align: center;
      white-space: nowrap;
    }
    .ghpr-ci-insight-header > .ghpr-item-navigator { margin-left: auto; }
    .ghpr-inline-finding-card > .ghpr-item-navigator {
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
      justify-content: flex-end;
      margin: -12px -14px 10px;
      padding: 8px 10px;
    }
    .ghpr-operation-card-actions {
      display: grid;
      gap: 6px;
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .ghpr-operation-card-actions .ghpr-action-button {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .ghpr-operation-card-actions .ghpr-action-button[data-primary="true"] {
      grid-column: 1 / -1;
    }
    .ghpr-operation-skill-menu {
      min-width: 0;
      position: relative;
    }
    .ghpr-operation-skill-menu > summary {
      align-items: center;
      appearance: none;
      background: var(--button-default-bgColor-rest, var(--bgColor-default, #f6f8fa));
      border: 1px solid var(--button-default-borderColor-rest, var(--borderColor-default, #d1d9e0));
      border-radius: 6px;
      cursor: pointer;
      display: flex;
      font-weight: 500;
      justify-content: center;
      list-style: none;
      min-height: 28px;
      overflow: hidden;
      padding: 3px 10px;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .ghpr-operation-skill-menu > summary::-webkit-details-marker { display: none; }
    .ghpr-operation-skill-menu > summary::after { content: " ▾"; }
    .ghpr-operation-skill-menu[open] > summary {
      background: var(--button-default-bgColor-hover, var(--bgColor-neutral-muted, #eaeef2));
    }
    .ghpr-operation-skill-menu-list {
      background: var(--overlay-bgColor, var(--bgColor-default, #fff));
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      box-shadow: var(--shadow-floating-small, 0 4px 12px rgba(31, 35, 40, .15));
      display: flex;
      flex-direction: column;
      min-width: 220px;
      padding: 5px;
      position: absolute;
      right: 0;
      top: calc(100% + 4px);
      z-index: 40;
    }
    .ghpr-operation-skill-menu-list .ghpr-action-button {
      background: transparent;
      border: 0;
      justify-content: flex-start;
      width: 100%;
    }
    .ghpr-operation-skill-menu > summary:focus-visible {
      outline: 2px solid var(--focus-outlineColor, #0969da);
      outline-offset: 2px;
    }
    .ghpr-operation-card-update:focus-visible {
      outline: 2px solid var(--focus-outlineColor, #0969da);
      outline-offset: 2px;
    }
    .ghpr-v2-highlight { animation: ghpr-highlight 2s ease-out; }
    @keyframes ghpr-highlight {
      0%, 45% { box-shadow: inset 3px 0 0 var(--borderColor-attention-emphasis, #bf8700); }
      100% { box-shadow: inset 3px 0 0 transparent; }
    }
    .ghpr-surface-drawer-backdrop {
      background: rgba(27, 31, 36, .45);
      inset: 0;
      position: fixed;
      z-index: 2147483600;
    }
    .ghpr-surface-drawer {
      background: var(--bgColor-default, #fff);
      border-left: 1px solid var(--borderColor-default, #d1d9e0);
      bottom: 0;
      box-shadow: -8px 0 24px rgba(31, 35, 40, .25);
      max-width: 92vw;
      overflow-y: auto;
      padding: 18px 42px 18px 18px;
      position: fixed;
      right: 0;
      top: 0;
      width: 440px;
    }
    .ghpr-surface-drawer-close {
      appearance: none;
      background: transparent;
      border: 0;
      color: var(--fgColor-muted, #656d76);
      cursor: pointer;
      font-size: 20px;
      line-height: 1;
      padding: 4px 8px;
      position: absolute;
      right: 8px;
      top: 8px;
    }
    .ghpr-drawer-title { font-size: 15px; font-weight: 600; margin: 0 0 4px; padding-right: 24px; }
    .ghpr-drawer-subtitle { color: var(--fgColor-muted, #656d76); margin: 0 0 12px; }
    .ghpr-drawer-section { margin-top: 14px; }
    .ghpr-drawer-section h4 { color: var(--fgColor-muted, #656d76); font-size: 11px; margin: 0 0 5px; }
    @media (max-width: 760px) {
      .ghpr-ci-insight-body { grid-template-columns: 1fr; }
      .ghpr-ci-result-rail { border-left: 0; border-top: 1px solid var(--borderColor-muted, #d8dee4); }
      .ghpr-job-verdict { min-width: 0; padding-left: 6px; }
      .ghpr-review-summary-meta { flex-direction: column; gap: 2px; }
      .ghpr-operation-card-host.ghpr-operation-card-floating {
        bottom: 8px;
        right: 8px;
        width: min(280px, calc(100vw - 16px));
      }
    }
    @media (prefers-reduced-motion: reduce) {
      .ghpr-v2-highlight { animation: none; box-shadow: inset 3px 0 0 var(--borderColor-attention-emphasis, #bf8700); }
      .ghpr-review-finding-preview-chevron { transition: none; }
    }
  `.trim();

  function h(document, tag, options = {}, children = []) {
    const element = document.createElement(tag);
    if (options.className) element.className = options.className;
    if (options.text !== undefined) element.textContent = options.text;
    if (options.html !== undefined) element.innerHTML = options.html;
    if (options.attrs) {
      for (const [key, value] of Object.entries(options.attrs)) {
        if (value === undefined || value === null || value === false) continue;
        element.setAttribute(key, value === true ? "" : String(value));
      }
    }
    if (options.dataset) {
      for (const [key, value] of Object.entries(options.dataset)) {
        if (value === undefined || value === null) continue;
        element.dataset[key] = String(value);
      }
    }
    if (options.onClick) element.addEventListener("click", options.onClick);
    for (const child of children) {
      if (child === null || child === undefined) continue;
      element.append(child);
    }
    return element;
  }

  function cssEscape(value) {
    if (global.CSS && typeof global.CSS.escape === "function") return global.CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_\u00A0-\uFFFF-]/g, (ch) => `\\${ch}`);
  }

  function severityIcon(severity) {
    if (severity === "error") return "●";
    if (severity === "warning") return "▲";
    return "ⓘ";
  }

  function severityLabel(severity) {
    if (severity === "error") return "Error";
    if (severity === "warning") return "Warning";
    return "Info";
  }

  function renderSeverity(document, severity) {
    return h(document, "span", { className: "ghpr-severity", attrs: { "data-severity": severity } }, [
      h(document, "span", { className: "ghpr-severity-icon", text: severityIcon(severity), attrs: { "aria-hidden": "true" } }),
      h(document, "span", { text: severityLabel(severity) })
    ]);
  }

  function renderActionButton(document, action) {
    const button = h(document, "button", {
      className: "ghpr-action-button",
      text: action.label,
      attrs: {
        type: "button",
        "data-primary": action.primary ? "true" : undefined,
        "data-action-id": action.id,
        disabled: action.disabled ? "" : undefined
      }
    });
    if (typeof action.onSelect === "function") {
      button.addEventListener("click", () => action.onSelect(action.id));
    }
    return button;
  }

  // A clipboard write has no other visible effect, so the button label is the
  // only feedback the surface can give. `onCopy` may return a boolean or a
  // promise of one; `false` reports a failed write.
  function renderCopyButton(document, {
    id = "copy",
    label = "Copy",
    ariaLabel,
    className = "ghpr-finding-copy",
    onCopy
  } = {}) {
    const button = h(document, "button", {
      className,
      text: label,
      attrs: {
        type: "button",
        "data-action-id": id,
        "aria-label": ariaLabel || label
      }
    });
    const view = document.defaultView || global;
    let resetTimer = null;
    const report = (copied) => {
      button.textContent = copied ? "Copied" : "Copy failed";
      button.setAttribute("data-copy-state", copied ? "copied" : "failed");
      if (resetTimer) view.clearTimeout(resetTimer);
      resetTimer = view.setTimeout(() => {
        resetTimer = null;
        if (!button.isConnected) return;
        button.textContent = label;
        button.removeAttribute("data-copy-state");
      }, 1500);
    };
    button.addEventListener("click", (event) => {
      event.preventDefault();
      // The preview card that hosts this button is itself clickable.
      event.stopPropagation();
      if (typeof onCopy !== "function") return;
      Promise.resolve()
        .then(() => onCopy(id))
        .then((result) => report(result !== false), () => report(false));
    });
    button.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") event.stopPropagation();
    });
    return button;
  }

  function renderItemNavigator(document, model = {}) {
    const position = Math.max(1, Number(model.position) || 1);
    const total = Math.max(position, Number(model.total) || position);
    const noun = model.noun || "items";
    return h(document, "nav", {
      className: "ghpr-item-navigator",
      attrs: { "aria-label": model.ariaLabel || `${noun} navigation` }
    }, [
      renderActionButton(document, {
        id: model.previousID || "previous",
        label: "Previous",
        disabled: typeof model.onPrevious !== "function",
        onSelect: model.onPrevious
      }),
      h(document, "span", {
        className: "ghpr-item-navigator-count",
        text: `${position} of ${total} ${noun}`
      }),
      renderActionButton(document, {
        id: model.nextID || "next",
        label: "Next",
        disabled: typeof model.onNext !== "function",
        onSelect: model.onNext
      })
    ]);
  }

  function formatProgressLogTime(value) {
    const timestamp = new Date(value);
    if (Number.isNaN(timestamp.getTime())) return "—";
    return timestamp.toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false
    });
  }

  function renderProgressLines(document, entries) {
    const markers = { queued: "·", running: "›", success: "✓", warning: "!", error: "×" };
    return h(document, "div", {
      className: "ghpr-operation-progress-log",
      attrs: { role: "log", "aria-live": "polite" }
    }, entries.map((entry, index) => h(document, "div", {
      className: "ghpr-operation-progress-line",
      attrs: { "data-kind": entry.kind || "running" }
    }, [
      h(document, "span", {
        className: "ghpr-operation-progress-line-number",
        text: String(index + 1),
        attrs: { title: formatProgressLogTime(entry.timestamp) }
      }),
      h(document, "span", {
        className: "ghpr-operation-progress-marker",
        text: markers[entry.kind] || "·",
        attrs: { "aria-hidden": "true" }
      }),
      h(document, "code", { text: entry.message || "" })
    ])));
  }

  function renderProgressStep(document, step) {
    const entries = Array.isArray(step.entries) ? step.entries : [];
    const markers = { running: "›", success: "✓", warning: "!", error: "×" };
    const log = renderProgressLines(document, entries);
    const details = h(document, "details", {
      className: "ghpr-operation-progress-step",
      attrs: { "data-status": step.status || "running" }
    }, [
      h(document, "summary", {}, [
        h(document, "span", {
          className: "ghpr-operation-progress-step-marker",
          text: markers[step.status] || "·",
          attrs: { "aria-hidden": "true" }
        }),
        h(document, "span", { text: step.label || "Step" }),
        h(document, "span", {
          className: "ghpr-operation-progress-step-meta",
          text: `${entries.length} ${entries.length === 1 ? "line" : "lines"}`
        })
      ]),
      log
    ]);
    details.open = Boolean(step.expanded);
    details.addEventListener("toggle", () => {
      if (typeof step.onToggle === "function") step.onToggle(details.open);
      if (details.open) log.scrollTop = log.scrollHeight;
    });
    return details;
  }

  function renderProgressLog(document, model = {}) {
    const steps = Array.isArray(model.steps) ? model.steps : [];
    const entries = Array.isArray(model.entries) ? model.entries : [];
    const content = steps.length
      ? h(document, "div", { className: "ghpr-operation-progress-steps" },
          steps.map((step) => renderProgressStep(document, step)))
      : renderProgressLines(document, entries);
    const details = h(document, "details", {
      className: "ghpr-operation-progress"
    }, [
      h(document, "summary", {}, [
        h(document, "span", { text: model.label || "Review log" }),
        h(document, "span", {
          className: "ghpr-operation-progress-state",
          text: model.progressText || entries.at(-1)?.message || "Waiting for review output…"
        })
      ]),
      content
    ]);
    details.open = Boolean(model.expanded);
    details.addEventListener("toggle", () => {
      if (typeof model.onToggle === "function") model.onToggle(details.open);
      if (!details.open) return;
      for (const log of details.querySelectorAll(".ghpr-operation-progress-step[open] .ghpr-operation-progress-log")) {
        log.scrollTop = log.scrollHeight;
      }
    });
    return details;
  }

  // model: { state, statusLabel, summary, signals:[{label,tone}], progressLog,
  //          updateAction, primaryAction, skillActions:[], actions:[],
  //          collapsible, collapsed, onToggle }
  function renderOperationCard(document, model = {}) {
    const head = [
      h(document, "span", {
        className: "ghpr-operation-card-mark",
        text: "gh",
        attrs: { "aria-hidden": "true" }
      }),
      h(document, "strong", { className: "ghpr-operation-card-title", text: "ghpr" }),
      h(document, "span", {
        className: "ghpr-operation-card-status",
        text: model.statusLabel || "Ready",
        attrs: { "aria-live": model.state === "running" ? "polite" : undefined }
      })
    ];
    if (model.updateAction) {
      const update = h(document, "button", {
        className: "ghpr-operation-card-update",
        text: model.updateAction.label || "Update",
        attrs: { type: "button", "data-action-id": model.updateAction.id || "update-userscript" }
      });
      if (typeof model.updateAction.onSelect === "function") {
        update.addEventListener("click", model.updateAction.onSelect);
      }
      head.push(update);
    }
    if (model.collapsible) {
      const collapsed = Boolean(model.collapsed);
      head.push(h(document, "button", {
        className: "ghpr-operation-card-toggle",
        text: collapsed ? "▴" : "▾",
        attrs: {
          type: "button",
          "data-action-id": "toggle-operation-card",
          "aria-label": collapsed ? "Expand ghpr card" : "Collapse ghpr card",
          "aria-expanded": collapsed ? "false" : "true"
        },
        onClick: () => model.onToggle?.(!collapsed)
      }));
    }

    const body = [];
    if (model.summary) {
      body.push(h(document, "p", {
        className: "ghpr-operation-card-summary",
        text: model.summary
      }));
    }
    if (model.signals?.length) {
      body.push(h(document, "div", { className: "ghpr-operation-card-signals" },
        model.signals.map((signal) => h(document, "span", {
          className: "ghpr-operation-card-signal",
          text: signal.label,
          attrs: { "data-tone": signal.tone }
        }))
      ));
    }
    if (model.progressLog) body.push(renderProgressLog(document, model.progressLog));
    const actions = [model.primaryAction, ...(model.actions || [])]
      .filter(Boolean)
      .map((action, index) => renderActionButton(document, {
        ...action,
        primary: index === 0 && Boolean(model.primaryAction)
      }));
    if (model.skillActions?.length) {
      actions.splice(Math.max(actions.length - 1, model.primaryAction ? 1 : 0), 0,
        h(document, "details", { className: "ghpr-operation-skill-menu" }, [
          h(document, "summary", { text: "Run Skill" }),
          h(document, "div", { className: "ghpr-operation-skill-menu-list" },
            model.skillActions.map((action) => renderActionButton(document, action))
          )
        ])
      );
    }
    if (actions.length) {
      body.push(h(document, "div", { className: "ghpr-operation-card-actions" }, actions));
    }

    return h(document, "section", {
      className: "ghpr-surface ghpr-operation-card",
      attrs: {
        "aria-label": "ghpr operations",
        "data-state": model.state || "ready",
        "data-collapsed": model.collapsible ? String(Boolean(model.collapsed)) : undefined
      }
    }, [
      h(document, "div", { className: "ghpr-operation-card-head" }, head),
      h(document, "div", {
        className: "ghpr-operation-card-body",
        attrs: { hidden: model.collapsible && model.collapsed }
      }, body)
    ]);
  }

  // --- job_verdict --------------------------------------------------------
  // model: { status, confidencePercent, actions: [{id,label,primary,onSelect}] }
  function renderJobVerdict(document, model = {}) {
    const status = model.status || "idle";
    const labels = {
      queued: "Investigating…",
      running: "Investigating…",
      likely_flaky: "Likely flaky",
      likely_related: "Likely related",
      needs_investigation: "Needs investigation",
      failed: "Analysis failed"
    };
    const children = [];
    if (status !== "idle") {
      const confidence = typeof model.confidencePercent === "number" &&
        Number.isFinite(model.confidencePercent)
        ? ` · ${Math.round(model.confidencePercent)}%`
        : "";
      children.push(h(document, "span", {
        className: "ghpr-job-verdict-copy",
        text: `${labels[status] || status}${confidence}`,
        attrs: { "aria-live": status === "queued" || status === "running" ? "polite" : undefined }
      }));
    }
    for (const action of model.actions || []) {
      children.push(renderActionButton(document, action));
    }
    return h(document, "span", {
      className: "ghpr-surface ghpr-job-verdict",
      attrs: { "data-status": status }
    }, children);
  }

  // --- ci_insight ----------------------------------------------------------
  // model: {
  //   explain: { status: 'unavailable'|'running'|'ready', whyItFailed, relevantEvidence:[], suggestedAction, onViewFullResult, onAction, actions:[] },
  //   classify: { status, verdict, confidencePercent, flakyEvidence:[], history:{failedRuns,totalRuns,windowDays}, reproduction, suggestedAction, onViewFullResult, actions:[] }
  // }
  function renderList(document, items) {
    return h(document, "ul", { className: "ghpr-ci-insight-list" }, (items || []).map((item) =>
      h(document, "li", { text: item })
    ));
  }

  function renderNarrative(document, heading, content) {
    if (content === undefined || content === null || content === "") return null;
    const body = Array.isArray(content)
      ? renderList(document, content)
      : h(document, "p", { text: content });
    return h(document, "section", { className: "ghpr-ci-insight-narrative" }, [
      h(document, "h4", { text: heading }),
      body
    ]);
  }

  function historyText(history) {
    if (!history) return null;
    const { failedRuns, totalRuns, windowDays } = history;
    const rate = totalRuns > 0 ? ` (${Math.round((failedRuns / totalRuns) * 100)}%)` : "";
    return `Failed ${failedRuns}/${totalRuns} runs${rate} in the last ${windowDays} days.`;
  }

  function renderInsightCopy(document, section, kind, options = {}) {
    if (!section || section.status === "unavailable") {
      return h(document, "p", {
        className: "ghpr-ci-insight-unavailable",
        text: "No analysis is available for this job yet."
      });
    }
    if (section.status === "running") {
      return h(document, "p", {
        attrs: { "aria-live": "polite" },
        text: "Investigating this job…"
      });
    }
    const body = [];
    if (kind === "explain") {
      body.push(renderNarrative(document, "Why it failed", section.whyItFailed));
      body.push(renderNarrative(document, "Relevant evidence", section.relevantEvidence));
    } else {
      const verdict = section.verdict
        ? `${section.verdict}${typeof section.confidencePercent === "number" ? ` · ${Math.round(section.confidencePercent)}% confidence` : ""}`
        : null;
      body.push(renderNarrative(document, "Classification", verdict));
      body.push(renderNarrative(document, "Flaky evidence", section.flakyEvidence));
      body.push(renderNarrative(document, "History", historyText(section.history)));
      body.push(renderNarrative(document, "Reproduction", section.reproduction));
    }
    if (options.includeSuggestedAction !== false) {
      body.push(renderNarrative(document, "Suggested action", section.suggestedAction));
    }
    return h(document, "div", {}, body.filter(Boolean));
  }

  function resultState(explain, classify) {
    if (explain?.status === "running" || classify?.status === "running") {
      return { status: "running", icon: "◌", label: "Investigating" };
    }
    if (explain?.status === "ready" || classify?.status === "ready") {
      return { status: "ready", icon: "✓", label: "Analysis ready" };
    }
    return { status: "unavailable", icon: "○", label: "Not analyzed" };
  }

  function sectionActions(section) {
    const actions = [...(section?.actions || [])];
    if (typeof section?.onViewFullResult === "function") {
      actions.push({ id: "details", label: "View full result", onSelect: section.onViewFullResult });
    }
    return actions;
  }

  function renderChecksCiInsight(document, model) {
    const state = resultState(model.explain, model.classify);
    const actionMap = new Map();
    for (const action of [...sectionActions(model.explain), ...sectionActions(model.classify)]) {
      if (!actionMap.has(action.id || action.label)) actionMap.set(action.id || action.label, action);
    }
    const explainHasSuggestion = Boolean(model.explain?.suggestedAction);
    const classifyHasSuggestion = Boolean(model.classify?.suggestedAction);
    const copy = h(document, "div", { className: "ghpr-ci-insight-copy" }, [
      renderInsightCopy(document, model.explain, "explain", {
        includeSuggestedAction: !classifyHasSuggestion
      }),
      renderInsightCopy(document, model.classify, "classify", {
        includeSuggestedAction: classifyHasSuggestion || !explainHasSuggestion
      })
    ]);
    const resultCard = h(document, "div", {
      className: "ghpr-ci-result-card",
      attrs: { "data-status": state.status }
    }, [
      h(document, "div", { className: "ghpr-ci-result-card-head" }, [
        h(document, "span", { className: "ghpr-ci-result-card-status", text: state.icon, attrs: { "aria-hidden": "true" } }),
        h(document, "span", { text: state.label })
      ]),
      h(document, "div", { className: "ghpr-ci-result-card-actions" },
        Array.from(actionMap.values()).map((action) => renderActionButton(document, action)))
    ]);
    const header = [
      h(document, "strong", { className: "ghpr-ci-insight-title", text: "ghpr CI Insight" }),
      h(document, "span", { className: "ghpr-beta-pill", text: "Beta" })
    ];
    if (model.navigation) header.push(renderItemNavigator(document, model.navigation));
    return h(document, "div", { className: "ghpr-surface ghpr-ci-insight", attrs: { "data-layout": "checks" } }, [
      h(document, "div", { className: "ghpr-ci-insight-header" }, header),
      h(document, "div", { className: "ghpr-ci-insight-body" }, [
        copy,
        h(document, "aside", { className: "ghpr-ci-result-rail" }, [resultCard])
      ])
    ]);
  }

  function renderActionsTabCopy(document, tabID, explain, classify) {
    const ready = (section) => section?.status === "ready";
    const running = (section) => section?.status === "running";
    const unavailable = () => h(document, "p", {
      className: "ghpr-ci-insight-unavailable",
      text: "No analysis is available for this job yet."
    });
    const investigating = () => h(document, "p", {
      attrs: { "aria-live": "polite" },
      text: "Investigating this job…"
    });

    if (tabID === "why") {
      if (!ready(explain)) return running(explain) ? investigating() : unavailable();
      return h(document, "div", {}, [
        renderNarrative(document, "Why it failed", explain.whyItFailed),
        renderNarrative(document, "Relevant evidence", explain.relevantEvidence)
      ].filter(Boolean));
    }
    if (tabID === "flaky") {
      if (!ready(classify)) return running(classify) ? investigating() : unavailable();
      const verdict = classify.verdict
        ? `${classify.verdict}${typeof classify.confidencePercent === "number" ? ` · ${Math.round(classify.confidencePercent)}% confidence` : ""}`
        : null;
      return h(document, "div", {}, [
        renderNarrative(document, "Classification", verdict),
        renderNarrative(document, "Flaky evidence", classify.flakyEvidence),
        renderNarrative(document, "Reproduction", classify.reproduction)
      ].filter(Boolean));
    }
    if (tabID === "history") {
      if (!ready(classify)) return running(classify) ? investigating() : unavailable();
      return renderNarrative(document, "History", historyText(classify.history)) || unavailable();
    }

    const suggestions = [explain, classify]
      .filter(ready)
      .map((section) => section.suggestedAction)
      .filter((value, index, values) => value && values.indexOf(value) === index);
    if (suggestions.length) {
      return renderNarrative(
        document,
        "Suggested action",
        suggestions.length === 1 ? suggestions[0] : suggestions
      );
    }
    return running(explain) || running(classify) ? investigating() : unavailable();
  }

  function renderActionsCiInsight(document, model) {
    const tabs = [
      { id: "why", label: "Why it failed" },
      { id: "flaky", label: "Flaky evidence" },
      { id: "history", label: "History" },
      { id: "suggested", label: "Suggested action" }
    ];
    const tabList = h(document, "div", { className: "ghpr-ci-tabs", attrs: { role: "tablist", "aria-label": "CI insight" } });
    const content = h(document, "div", { className: "ghpr-ci-actions-content" });
    const buttons = [];
    const selectTab = (selected) => {
      for (let index = 0; index < tabs.length; index += 1) {
        buttons[index].setAttribute("aria-selected", index === selected ? "true" : "false");
        buttons[index].setAttribute("tabindex", index === selected ? "0" : "-1");
      }
      content.replaceChildren(renderActionsTabCopy(
        document,
        tabs[selected].id,
        model.explain,
        model.classify
      ));
    };
    tabs.forEach((tab, index) => {
      const button = h(document, "button", {
        className: "ghpr-ci-tab",
        text: tab.label,
        attrs: { type: "button", role: "tab", "aria-selected": index === 0 ? "true" : "false" },
        onClick: () => selectTab(index)
      });
      button.addEventListener("keydown", (event) => {
        const delta = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
        const target = event.key === "Home"
          ? 0
          : event.key === "End"
            ? tabs.length - 1
            : delta
              ? (index + delta + tabs.length) % tabs.length
              : null;
        if (target === null) return;
        event.preventDefault();
        selectTab(target);
        buttons[target].focus();
      });
      buttons.push(button);
      tabList.append(button);
    });
    selectTab(0);
    const actionMap = new Map();
    for (const action of [...sectionActions(model.explain), ...sectionActions(model.classify)]) {
      if (!actionMap.has(action.id || action.label)) actionMap.set(action.id || action.label, action);
    }
    return h(document, "div", { className: "ghpr-surface ghpr-ci-insight", attrs: { "data-layout": "actions" } }, [
      h(document, "div", { className: "ghpr-ci-insight-header" }, [
        h(document, "strong", { className: "ghpr-ci-insight-title", text: "ghpr CI Insight" }),
        h(document, "span", { className: "ghpr-beta-pill", text: "Beta" }),
        model.jobName ? h(document, "span", { className: "ghpr-ci-insight-unavailable", text: `Matched failure · ${model.jobName}` }) : null
      ]),
      tabList,
      content,
      h(document, "div", { className: "ghpr-ci-actions-footer" },
        Array.from(actionMap.values()).map((action) => renderActionButton(document, action)))
    ]);
  }

  function renderCiInsight(document, model = {}) {
    return model.surfaceMode === "actions_job"
      ? renderActionsCiInsight(document, model)
      : renderChecksCiInsight(document, model);
  }

  // --- diff_snippet ---------------------------------------------------------
  // model: { lines: [{ kind: 'context'|'added'|'removed'|'ellipsis', text }] }
  function renderDiffSnippet(document, model = {}) {
    const lines = model.lines || [];
    if (!lines.length) {
      return h(document, "div", { className: "ghpr-surface ghpr-diff-snippet", text: "snippet unavailable" });
    }
    return h(document, "pre", { className: "ghpr-surface ghpr-diff-snippet" }, lines.map((line) =>
      h(document, "div", {
        className: "ghpr-diff-snippet-line",
        attrs: { "data-kind": line.kind || "context" },
        text: line.kind === "ellipsis" ? "…" : line.text
      })
    ));
  }

  // --- review_finding / review_finding_preview -------------------------------
  // model: {
  //   id, title, severity, confidencePercent, filePath, side, startLine, endLine,
  //   summary, details, quotedCode, snippet: diff_snippet model | null, expanded,
  //   inline (diff-line variant), fileLevel (file-scope variant),
  //   showSummary (render the clamped summary line),
  //   locationLabel (overrides the derived "path · Lx-Ly" text),
  //   reviewedShortSHA (the commit the finding was reviewed against),
  //   lifecycleLabel/lifecycleTone (e.g. "Outdated"/"danger"),
  //   onToggle(id, element), onCollapse, onOpenInEditor, onDismiss, onCopyFinding,
  //   onRawDiagnostics, onShowReviewedRevision
  // }
  function locationText(model) {
    if (!model.filePath) return "";
    const range = model.startLine === model.endLine || !model.endLine
      ? `L${model.startLine}`
      : `L${model.startLine}-L${model.endLine}`;
    const parts = [model.filePath, range];
    if (model.reviewedShortSHA) parts.push(`reviewed ${model.reviewedShortSHA}`);
    return parts.join(" · ");
  }

  // Plain text, so a copied finding pastes cleanly into a review comment, an
  // issue, or a chat message. The same shape is reused by the summary's
  // "Copy all", which is why it lives next to the renderers it mirrors.
  function findingCopyText(model = {}) {
    const lines = [`[${severityLabel(model.severity || "info")}] ${model.title || "Review finding"}`];
    const meta = [];
    const location = locationText(model) || model.locationLabel || "";
    if (location) meta.push(location);
    if (typeof model.confidencePercent === "number") {
      meta.push(`${Math.round(model.confidencePercent)}% confidence`);
    }
    if (model.fileLevel) meta.push("File-level");
    if (model.lifecycleLabel) meta.push(model.lifecycleLabel);
    if (meta.length) lines.push(meta.join(" · "));
    if (model.summary && model.summary !== model.title) lines.push("", model.summary);
    if (model.details) lines.push("", model.details);
    const snippet = (model.snippet?.lines || [])
      .map((line) => (line.kind === "ellipsis" ? "…" : line.text))
      .join("\n");
    if (snippet) lines.push("", "```diff", snippet, "```");
    return lines.join("\n");
  }

  function reviewSummaryCopyText(model = {}) {
    const findings = model.findings || [];
    const findingCount = typeof model.findingCount === "number" ? model.findingCount : findings.length;
    const header = [model.title || "ghpr Review Summary"];
    const revisionText = model.revisionText || (model.reviewedShortSHA
      ? `Reviewed revision ${model.reviewedShortSHA}${model.isLatest ? " · latest" : ""}`
      : "");
    if (revisionText) header.push(revisionText);
    header.push(`${findingCount} findings · ${model.fileCount || 0} files`);
    return [
      header.join("\n"),
      ...findings.map((finding, index) => `${index + 1}. ${findingCopyText(finding)}`)
    ].join("\n\n");
  }

  function renderLifecycleChip(document, model) {
    if (!model.lifecycleLabel) return null;
    return h(document, "span", {
      className: "ghpr-lifecycle-chip",
      text: model.lifecycleLabel,
      attrs: { "data-tone": model.lifecycleTone || "attention" }
    });
  }

  // A file-scoped finding has no diff line to sit on, so it says so explicitly
  // instead of borrowing the inline card's shape.
  function renderScopeChip(document, model) {
    if (!model.fileLevel) return null;
    return h(document, "span", {
      className: "ghpr-finding-scope-chip",
      text: "File-level"
    });
  }

  function renderReviewFindingPreview(document, model = {}) {
    const expanded = model.expanded ? "true" : "false";
    const preview = h(document, "div", {
      className: "ghpr-surface ghpr-review-finding-preview",
      attrs: {
        "data-expanded": expanded,
        "data-inline": model.inline ? "true" : "false",
        "data-file-level": model.fileLevel ? "true" : "false",
        "data-severity": model.severity || "info",
        "aria-expanded": expanded,
        role: "button",
        tabindex: "0"
      }
    }, [
      renderSeverity(document, model.severity || "info"),
      h(document, "span", { className: "ghpr-review-finding-title", text: model.title || "" }),
      typeof model.confidencePercent === "number"
        ? h(document, "span", { className: "ghpr-review-finding-confidence", text: `${Math.round(model.confidencePercent)}%` })
        : null,
      renderScopeChip(document, model),
      renderLifecycleChip(document, model),
      typeof model.onCopyFinding === "function"
        ? renderCopyButton(document, {
            id: "copy-finding",
            ariaLabel: `Copy finding: ${model.title || "Review finding"}`,
            onCopy: () => model.onCopyFinding(model.id)
          })
        : null,
      h(document, "span", { className: "ghpr-review-finding-preview-chevron", text: "›", attrs: { "aria-hidden": "true" } }),
      h(document, "span", {
        className: "ghpr-review-finding-location ghpr-review-finding-preview-location",
        text: model.locationLabel || locationText(model)
      }),
      model.showSummary && model.summary && model.summary !== model.title
        ? h(document, "p", { className: "ghpr-review-finding-preview-summary", text: model.summary })
        : null,
      model.snippet ? renderDiffSnippet(document, model.snippet) : null
    ]);
    if (typeof model.onToggle === "function") {
      preview.addEventListener("click", () => model.onToggle(model.id, preview));
      preview.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          model.onToggle(model.id, preview);
        }
      });
    }
    return preview;
  }

  function renderReviewFinding(document, model = {}) {
    const head = h(document, "div", { className: "ghpr-review-finding-head" }, [
      renderSeverity(document, model.severity || "info"),
      h(document, "span", {
        className: "ghpr-review-finding-title",
        text: model.title || "",
        attrs: { tabindex: "-1" }
      }),
      typeof model.confidencePercent === "number"
        ? h(document, "span", { className: "ghpr-review-finding-confidence", text: `${Math.round(model.confidencePercent)}% confidence` })
        : null,
      renderScopeChip(document, model),
      renderLifecycleChip(document, model)
    ]);
    const body = [
      h(document, "div", { className: "ghpr-review-finding-location", text: locationText(model) })
    ];
    if (model.summary) body.push(h(document, "p", { text: model.summary }));
    if (model.details) body.push(h(document, "p", { text: model.details }));
    if (model.snippet) body.push(renderDiffSnippet(document, model.snippet));

    const actions = [];
    if (typeof model.onCollapse === "function") {
      actions.push(renderActionButton(document, {
        id: "collapse-finding",
        label: "Collapse",
        onSelect: model.onCollapse
      }));
    }
    if (typeof model.onOpenInFiles === "function") {
      actions.push(renderActionButton(document, {
        id: "view-diff-context",
        label: "View diff context",
        onSelect: model.onOpenInFiles
      }));
    }
    if (!model.summaryMode && typeof model.onOpenInEditor === "function") {
      actions.push(renderActionButton(document, {
        id: "open-editor",
        label: "Open in editor",
        onSelect: model.onOpenInEditor
      }));
    }
    if (!model.summaryMode && typeof model.onDismiss === "function") {
      actions.push(renderActionButton(document, {
        id: "dismiss",
        label: "Dismiss",
        onSelect: model.onDismiss
      }));
    } else if (!model.summaryMode && typeof model.onRequestDismissPermission === "function") {
      actions.push(renderActionButton(document, {
        id: "grant-dismiss",
        label: "Grant permission to dismiss",
        onSelect: model.onRequestDismissPermission
      }));
    }
    // Copying a finding is useful wherever it renders, including inside the
    // Review Summary, so it is not gated behind summaryMode like the mutating
    // actions are.
    if (typeof model.onCopyFinding === "function") {
      actions.push(renderCopyButton(document, {
        id: "copy-finding",
        label: "Copy finding",
        className: "ghpr-action-button",
        ariaLabel: `Copy finding: ${model.title || "Review finding"}`,
        onCopy: () => model.onCopyFinding(model.id)
      }));
    }
    if (!model.summaryMode) {
      for (const [label, handler] of [
        ["Raw diagnostics", model.onRawDiagnostics],
        ["Show reviewed revision", model.onShowReviewedRevision]
      ]) {
        if (typeof handler !== "function") continue;
        actions.push(renderActionButton(document, { id: label, label, onSelect: handler }));
      }
    }
    if (actions.length) body.push(h(document, "div", { className: "ghpr-finding-tools" }, actions));

    return h(document, "div", {
      className: "ghpr-surface ghpr-review-finding",
      attrs: model.id ? { "data-finding-id": model.id } : {}
    }, [
      head,
      h(document, "div", { className: "ghpr-review-finding-body" }, body)
    ]);
  }

  // --- finding_count ---------------------------------------------------------
  // model: { count, onOpen }
  function renderFindingCount(document, model = {}) {
    const count = model.count || 0;
    const label = model.label || (count === 1 ? "1 finding" : `${count} findings`);
    const pill = h(document, "button", {
      className: "ghpr-surface ghpr-finding-count-pill",
      text: `ghpr · ${label}`,
      attrs: { type: "button", "aria-expanded": model.expanded ? "true" : "false" }
    });
    if (typeof model.onOpen === "function") pill.addEventListener("click", model.onOpen);
    return pill;
  }

  // model: {
  //   reviewedShortSHA, isLatest, findingCount, fileCount,
  //   findings: [review_finding_preview model, ...] (first entry rendered expanded with full body),
  //   onOpenInFiles, onUpdate, updateLabel, onCopyAll (copies the summary plus every finding)
  // }
  function renderReviewSummary(document, model = {}) {
    const identity = h(document, "div", { className: "ghpr-review-summary-identity" }, [
      h(document, "span", { className: "ghpr-review-summary-avatar", text: "gh", attrs: { "aria-hidden": "true" } }),
      h(document, "strong", { text: "ghpr-bot" }),
      h(document, "span", { className: "ghpr-review-summary-bot", text: "bot" }),
      h(document, "span", { className: "ghpr-review-summary-time", text: "reviewed this revision" })
    ]);
    const title = h(document, "div", { className: "ghpr-review-summary-title" }, [
      h(document, "strong", { text: "ghpr Review Summary" }),
      h(document, "span", { className: "ghpr-beta-pill", text: "Beta" })
    ]);
    const toolbar = [title];
    if (typeof model.onUpdate === "function") {
      toolbar.push(renderActionButton(document, {
        id: "update-userscript",
        label: model.updateLabel || "Update ghpr",
        onSelect: model.onUpdate
      }));
    }
    if (typeof model.onOpenInFiles === "function") {
      toolbar.push(renderActionButton(document, {
        id: "view-files",
        label: "View in Files changed",
        onSelect: model.onOpenInFiles
      }));
    }
    if (typeof model.onCopyAll === "function") {
      toolbar.push(renderCopyButton(document, {
        id: "copy-all",
        label: model.copyAllLabel || "Copy all",
        className: "ghpr-action-button",
        ariaLabel: "Copy the review summary and every finding",
        onCopy: model.onCopyAll
      }));
    }
    if (typeof model.onReview === "function") {
      toolbar.push(renderActionButton(document, {
        id: "review-pr",
        label: model.reviewLabel || "Review PR",
        disabled: Boolean(model.reviewDisabled),
        onSelect: model.onReview
      }));
    }
    const revisionText = model.revisionText || (model.isLatest
      ? `Reviewed revision ${model.reviewedShortSHA || ""} · latest`
      : `Reviewed revision ${model.reviewedShortSHA || ""}`);
    const meta = h(document, "div", { className: "ghpr-review-summary-meta" }, [
      h(document, "span", { text: revisionText }),
      h(document, "span", {
        text: `${model.findingCount || 0} findings · ${model.fileCount || 0} files`
      })
    ]);

    const findingsList = h(document, "div", { className: "ghpr-review-summary-findings" });
    const findings = model.findings || [];
    findings.forEach((finding, index) => {
      if (index === 0) {
        findingsList.append(renderReviewFinding(document, { ...finding, expanded: true, summaryMode: true }));
      } else {
        findingsList.append(renderReviewFindingPreview(document, finding));
      }
    });

    return h(document, "div", { className: "ghpr-surface ghpr-review-summary" }, [
      identity,
      h(document, "div", { className: "ghpr-review-summary-toolbar" }, toolbar),
      meta,
      findingsList
    ]);
  }

  // --- detail_drawer -----------------------------------------------------------
  // model: { title, subtitle, sections: [{heading, body}], actions: [{id, label, onSelect}], raw }
  function renderDetailDrawer(document, model = {}) {
    const children = [
      h(document, "h3", { className: "ghpr-drawer-title", text: model.title || "" })
    ];
    if (model.subtitle) children.push(h(document, "p", { className: "ghpr-drawer-subtitle", text: model.subtitle }));
    for (const section of model.sections || []) {
      children.push(h(document, "div", { className: "ghpr-drawer-section" }, [
        h(document, "h4", { text: section.heading }),
        typeof section.body === "string"
          ? h(document, "p", { text: section.body })
          : section.body
      ]));
    }
    const actions = (model.actions || []).map((action) =>
      renderActionButton(document, action)
    );
    if (actions.length) {
      children.push(h(document, "div", { className: "ghpr-finding-tools" }, actions));
    }
    if (model.raw) {
      children.push(h(document, "div", { className: "ghpr-drawer-section" }, [
        h(document, "h4", { text: "Raw result" }),
        h(document, "pre", { className: "ghpr-diff-snippet", text: model.raw })
      ]));
    }
    return h(document, "div", { className: "ghpr-surface" }, children);
  }

  const RENDERERS = Object.freeze({
    job_verdict: renderJobVerdict,
    ci_insight: renderCiInsight,
    review_summary: renderReviewSummary,
    review_finding_preview: renderReviewFindingPreview,
    finding_count: renderFindingCount,
    review_finding: renderReviewFinding,
    diff_snippet: renderDiffSnippet,
    detail_drawer: renderDetailDrawer
  });

  function renderSurface(document, viewType, model) {
    const renderer = RENDERERS[viewType];
    if (!renderer) {
      throw new Error(`ghpr surface-renderers: unknown view type "${viewType}"`);
    }
    return renderer(document, model || {});
  }

  function installSurfaceStyles(document) {
    if (document.getElementById(SURFACE_STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = SURFACE_STYLE_ID;
    style.textContent = SURFACE_STYLE_TEXT;
    document.head.appendChild(style);
  }

  // --- SurfaceMount: keyed idempotent insert/update/destroy at one host gap ----
  class SurfaceMount {
    constructor({ document, surfaceId, subjectKey = null, instanceKey = "default", host, anchor = null, position = "append" }) {
      this.document = document;
      this.surfaceId = surfaceId;
      this.subjectKey = subjectKey;
      this.instanceKey = instanceKey;
      this.host = host;
      this.anchor = anchor;
      this.position = position;
      this._element = null;
    }

    _locate() {
      if (!this.host) return null;
      const selector = `[data-ghpr-surface="${cssEscape(this.surfaceId)}"][data-ghpr-instance="${cssEscape(this.instanceKey)}"]`;
      return this.host.querySelector(selector);
    }

    _tag(contentElement) {
      contentElement.setAttribute("data-ghpr-surface", this.surfaceId);
      contentElement.setAttribute("data-ghpr-instance", this.instanceKey);
      if (this.subjectKey) contentElement.setAttribute("data-ghpr-subject-key", this.subjectKey);
      else contentElement.removeAttribute("data-ghpr-subject-key");
    }

    _insert(contentElement) {
      const { position, anchor, host } = this;
      if (position === "before" && anchor && anchor.parentNode) {
        anchor.parentNode.insertBefore(contentElement, anchor);
      } else if (position === "after" && anchor && anchor.parentNode) {
        anchor.parentNode.insertBefore(contentElement, anchor.nextSibling);
      } else if (position === "prepend" && host) {
        host.insertBefore(contentElement, host.firstChild);
      } else if (host) {
        host.appendChild(contentElement);
      }
    }

    mount(contentElement) {
      this._tag(contentElement);
      const existing = this._element && this._element.isConnected ? this._element : this._locate();
      if (existing && existing !== contentElement) {
        existing.replaceWith(contentElement);
      } else if (!existing) {
        this._insert(contentElement);
      }
      this._element = contentElement;
      return contentElement;
    }

    update(contentElement) {
      return this.mount(contentElement);
    }

    destroy() {
      const node = (this._element && this._element.isConnected ? this._element : null) || this._locate();
      if (node && node.parentNode) node.parentNode.removeChild(node);
      this._element = null;
    }

    get element() {
      return (this._element && this._element.isConnected ? this._element : null) || this._locate();
    }
  }

  // --- InlinePanelHost: one active panel, reused across subject switches ------
  class InlinePanelHost {
    constructor({ document, surfaceId }) {
      this.document = document;
      this.surfaceId = surfaceId;
      this._mount = null;
    }

    openAfter(targetRowElement, contentElement, { subjectKey = null, instanceKey = "panel" } = {}) {
      const host = targetRowElement.parentNode;
      if (
        !this._mount ||
        this._mount.host !== host ||
        this._mount.instanceKey !== instanceKey ||
        this._mount.anchor !== targetRowElement
      ) {
        this.close();
        this._mount = new SurfaceMount({
          document: this.document,
          surfaceId: this.surfaceId,
          subjectKey,
          instanceKey,
          host,
          anchor: targetRowElement,
          position: "after"
        });
      } else {
        this._mount.anchor = targetRowElement;
        this._mount.subjectKey = subjectKey;
      }
      return this._mount.mount(contentElement);
    }

    update(contentElement) {
      if (!this._mount) return null;
      return this._mount.update(contentElement);
    }

    close() {
      if (this._mount) this._mount.destroy();
      this._mount = null;
    }

    get isOpen() {
      return !!(this._mount && this._mount.element);
    }

    get subjectKey() {
      return this._mount ? this._mount.subjectKey : null;
    }
  }

  // --- DrawerHost: one body-level right drawer with focus trap -----------------
  class DrawerHost {
    constructor({ document }) {
      this.document = document;
      this._backdrop = null;
      this._panel = null;
      this._onClose = null;
      this._trigger = null;
      this._keydownHandler = (event) => this._onKeydown(event);
    }

    get isOpen() {
      return !!(this._backdrop && this._backdrop.isConnected);
    }

    open(contentElement, { onClose = null, triggerEl = null } = {}) {
      this.close();
      const document = this.document;
      this._trigger = triggerEl || document.activeElement || null;
      this._onClose = onClose;

      const backdrop = h(document, "div", {
        className: "ghpr-surface-drawer-backdrop",
        attrs: { "data-ghpr-surface": SURFACE_IDS.pageFindingDrawer },
        onClick: (event) => {
          if (event.target === backdrop) this.close();
        }
      });
      const closeButton = h(document, "button", {
        className: "ghpr-surface-drawer-close",
        text: "\u00d7",
        attrs: { type: "button", "aria-label": "Close" },
        onClick: () => this.close()
      });
      const panel = h(document, "div", {
        className: "ghpr-surface-drawer",
        attrs: { role: "dialog", "aria-modal": "true", tabindex: "-1" }
      }, [closeButton, contentElement]);
      backdrop.appendChild(panel);
      document.body.appendChild(backdrop);
      document.addEventListener("keydown", this._keydownHandler, true);

      this._backdrop = backdrop;
      this._panel = panel;
      if (typeof panel.focus === "function") panel.focus();
      return panel;
    }

    close() {
      if (!this._backdrop) return;
      const document = this.document;
      document.removeEventListener("keydown", this._keydownHandler, true);
      if (this._backdrop.parentNode) this._backdrop.parentNode.removeChild(this._backdrop);
      const trigger = this._trigger;
      const onClose = this._onClose;
      this._backdrop = null;
      this._panel = null;
      this._trigger = null;
      this._onClose = null;
      if (trigger && typeof trigger.focus === "function") trigger.focus();
      if (typeof onClose === "function") onClose();
    }

    _onKeydown(event) {
      if (!this._panel) return;
      if (event.key === "Escape") {
        event.preventDefault();
        this.close();
        return;
      }
      if (event.key !== "Tab") return;
      const focusable = Array.from(this._panel.querySelectorAll(
        'a[href], button:not([disabled]), textarea, input, select, [tabindex]:not([tabindex="-1"])'
      ));
      if (!focusable.length) {
        event.preventDefault();
        this._panel.focus();
        return;
      }
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = this.document.activeElement;
      if (event.shiftKey && active === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    }
  }

  // --- SurfaceRegistry: thin convenience wrapper over keyed SurfaceMounts -----
  class SurfaceRegistry {
    constructor({ document }) {
      this.document = document;
      this._mounts = new Map();
    }

    mount(surfaceId, host, model, viewType, opts = {}) {
      const instanceKey = opts.instanceKey || "default";
      const key = `${surfaceId}::${instanceKey}`;
      let mount = this._mounts.get(key);
      if (!mount) {
        mount = new SurfaceMount({
          document: this.document,
          surfaceId,
          instanceKey,
          host,
          anchor: opts.anchor || null,
          position: opts.position || "append",
          subjectKey: opts.subjectKey || null
        });
        this._mounts.set(key, mount);
      } else {
        mount.host = host;
        if (opts.anchor) mount.anchor = opts.anchor;
        if (opts.position) mount.position = opts.position;
        mount.subjectKey = opts.subjectKey || null;
      }
      const content = renderSurface(this.document, viewType, model);
      mount.mount(content);
      return content;
    }

    unmountStale(activeKeys) {
      const keep = new Set(activeKeys);
      for (const [key, mount] of this._mounts) {
        if (keep.has(key)) continue;
        mount.destroy();
        this._mounts.delete(key);
      }
    }

    destroyAll() {
      for (const mount of this._mounts.values()) mount.destroy();
      this._mounts.clear();
    }
  }

  const exported = {
    SURFACE_IDS,
    VIEW_TYPES,
    SURFACE_STYLE_ID,
    SURFACE_STYLE_TEXT,
    installSurfaceStyles,
    renderSurface,
    renderOperationCard,
    renderItemNavigator,
    renderJobVerdict,
    renderCiInsight,
    renderReviewSummary,
    renderReviewFindingPreview,
    renderReviewFinding,
    renderFindingCount,
    renderDiffSnippet,
    renderDetailDrawer,
    findingCopyText,
    reviewSummaryCopyText,
    SurfaceMount,
    InlinePanelHost,
    DrawerHost,
    SurfaceRegistry
  };

  global.GhprSurfaceRenderers = exported;
  if (typeof module !== "undefined" && module.exports) module.exports = exported;
})(typeof globalThis !== "undefined" ? globalThis : this);
// <<< END GENERATED: browser/surface-renderers.js

(function ghprUserscriptModule(global) {
  "use strict";

  const CLIENT = {
    id: "dev.ghpr.official-userscript",
    name: "ghpr for GitHub",
    version: "2.0.13",
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
      "app:open",
      "finding:write"
    ]
  };
  const DISCOVERY_PORTS = Array.from({ length: 10 }, (_, index) => 48120 + index);
  const STORAGE = {
    port: "ghpr.bridge.port",
    instance: "ghpr.bridge.instance",
    token: "ghpr.bridge.token",
    dismissedFindings: "ghpr.dismissed.findings"
  };
  const PERMISSION_LABELS = {
    "skill:run": "Run configured Skills",
    "skill:cancel": "Cancel Skill runs",
    "tag:write": "Change locally stored ghpr tags",
    "detail:open": "Open local analysis",
    "finding:write": "Dismiss review findings",
    "app:open": "Open ghpr-view"
  };
  const ROOT_ID = "ghpr-github-root";
  const HEADER_ENTRY_ID = "ghpr-header-entry";
  const OPERATION_CARD_ID = "ghpr-operation-card";
  const STYLE_ID = "ghpr-github-styles";
  const MANAGED_ATTRIBUTE = "data-ghpr-managed";
  const POLL_ACTIVE_MS = 2000;
  const POLL_IDLE_MS = 15000;
  // Discovery probes every port in turn, so it must fail fast. The page
  // snapshot resolves the current PR revision through the GitHub CLI, which
  // on large pull requests takes far longer than a discovery probe.
  const REQUEST_TIMEOUT_MS = 4000;
  const SNAPSHOT_TIMEOUT_MS = 20000;

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
    const setClipboard = source.setClipboard || legacy.GM_setClipboard;

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
      // Tampermonkey's clipboard write does not need document focus or the
      // async Clipboard API permission, so it is preferred when granted.
      setClipboard: setClipboard
        ? (text) => Promise.resolve(setClipboard.call(source, text, "text/plain"))
        : null,
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

    async request(
      method,
      path,
      body = null,
      authenticated = true,
      timeoutMs = REQUEST_TIMEOUT_MS
    ) {
      if (!this.baseURL) throw new BridgeError("Browser Bridge is offline.");
      return this.rawRequest(this.baseURL, method, path, body, authenticated, timeoutMs);
    }

    async rawRequest(
      baseURL,
      method,
      path,
      body = null,
      authenticated = false,
      timeoutMs = REQUEST_TIMEOUT_MS
    ) {
      const headers = { Accept: "application/json" };
      if (body !== null) headers["Content-Type"] = "application/json";
      if (authenticated && this.token) headers.Authorization = `Bearer ${this.token}`;
      const response = await this.gm.request({
        method,
        url: `${baseURL}${path}`,
        headers,
        timeout: timeoutMs,
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
    if (options.disabled) element.disabled = true;
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

  function confidencePercent(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return null;
    return `${Math.round(number <= 1 ? number * 100 : number)}%`;
  }

  function findingSeverityTone(severity) {
    if (severity === "error" || severity === "high") return "danger";
    if (severity === "warning" || severity === "medium") return "warning";
    return "info";
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

  function isFilesChangedSurface(locationLike) {
    const pathname = locationLike?.pathname || "/";
    return /^\/[^/]+\/[^/]+\/pull\/\d+\/(?:files|changes)(?:\/(?:[0-9a-f]{7,40}\.\.)?[0-9a-f]{7,40})?\/?$/
      .test(pathname);
  }

  // GitHub serves a historical revision of the PR diff at
  // /pull/<n>/files/<base>..<head> (and /files/<head> for a single commit).
  // Findings reviewed against that head are anchored with the line numbers they
  // were reported on there, not with the ones they were remapped to.
  function filesChangedRevisionRef(locationLike) {
    const pathname = locationLike?.pathname || "/";
    const match = pathname.match(
      /^\/[^/]+\/[^/]+\/pull\/\d+\/(?:files|changes)\/(?:[0-9a-f]{7,40}\.\.)?([0-9a-f]{7,40})\/?$/
    );
    return match ? match[1].toLowerCase() : null;
  }

  function labelForSkillAgent(value) {
    const normalized = String(value || "").trim().toLowerCase().replace(/[-\s]+/g, "_");
    switch (normalized) {
    case "claude_code": return "Claude Code";
    case "codex": return "Codex";
    case "omp": return "OMP";
    case "external": return "External";
    default: return value ? String(value).trim() : null;
    }
  }

  function isChecksSurface(locationLike) {
    const pathname = locationLike?.pathname || "/";
    return /^\/[^/]+\/[^/]+\/pull\/\d+\/checks\/?$/.test(pathname);
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
        "[role='region'][aria-label='Checks']",
        "section[aria-label='Checks']",
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
        "section[data-file-tree-expanded]",
        "#files .pr-toolbar",
        ".diffbar"
      ],
      "files.diff.line-decoration": [
        "table.diff-table",
        "table[data-diff-anchor]"
      ],
      "files.tree.file": [
        "[role='treeitem'][id][aria-label]"
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

  function parseWorkflowJobHref(href) {
    if (!href) return null;
    try {
      const url = new URL(href, "https://github.com");
      const match = url.pathname.match(/^\/([^/]+\/[^/]+)\/actions\/runs\/(\d+)\/job\/(\d+)/);
      if (!match) return null;
      return { repository: match[1], runId: match[2], jobId: match[3] };
    } catch (_) {
      return null;
    }
  }

  function workflowJobSubjectKey({ repository, runId, jobId }) {
    return `github:workflow-job:${String(repository).toLowerCase()}:run:${runId}:job:${jobId}`;
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
      .ghpr-file-tree-badge {
        align-items: center;
        background: var(--ghpr-purple);
        border: 1px solid var(--ghpr-purple-strong);
        border-radius: 999px;
        color: #fff;
        display: inline-flex;
        flex: 0 0 auto;
        font-size: 10px;
        font-weight: 700;
        height: 16px;
        justify-content: center;
        line-height: 1;
        margin-inline-start: 4px;
        min-width: 16px;
        padding: 0 4px;
      }
      .ghpr-header-entry {
        align-items: center; display: inline-flex; flex: 0 0 auto;
        position: relative; vertical-align: middle; z-index: 1;
      }
      .ghpr-header-entry:not(.ghpr-header-floating) { margin-inline: 4px; }
      .ghpr-header-entry.ghpr-header-floating {
        position: fixed; right: 16px; top: 72px; z-index: 2147483000;
      }
      body:has(> .ghpr-header-entry.ghpr-header-floating) > #${ROOT_ID}.ghpr-floating {
        top: 120px;
      }
      .ghpr-header-button {
        appearance: none; background: var(--ghpr-panel); border: 1px solid var(--ghpr-border);
        border-radius: 6px; color: var(--ghpr-ink); cursor: pointer; font: inherit;
        font-weight: 650; height: 32px; line-height: 1.35; padding: 5px 9px;
        white-space: nowrap;
      }
      .ghpr-header-button:hover { background: color-mix(in srgb, var(--ghpr-purple) 10%, var(--ghpr-panel)); }
      .ghpr-header-menu {
        background: var(--ghpr-panel); border: 1px solid var(--ghpr-border); border-radius: 8px;
        box-shadow: 0 8px 24px rgba(31, 35, 40, .2); color: var(--ghpr-ink);
        min-width: 270px; padding: 9px; position: absolute; right: 0; top: calc(100% + 6px);
      }
      .ghpr-header-menu[hidden] { display: none; }
      .ghpr-header-menu-title { font-size: 13px; font-weight: 750; margin-bottom: 6px; }
      .ghpr-header-menu-summary { color: var(--ghpr-muted); margin: 0 0 8px; }
      .ghpr-header-menu .ghpr-section { margin-top: 8px; }
      .ghpr-header-menu .ghpr-panel-action { min-height: 28px; }
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
      .ghpr-review-meta, .ghpr-finding-meta {
        color: var(--ghpr-muted); font-size: 11px; margin: 5px 0;
      }
      .ghpr-finding {
        border-top: 1px solid var(--ghpr-border); margin-top: 8px; padding-top: 8px;
      }
      .ghpr-finding-head { align-items: center; display: flex; gap: 6px; justify-content: space-between; }
      .ghpr-finding-title { font-weight: 700; min-width: 0; }
      .ghpr-finding-title code { font-size: 11px; font-weight: 500; }
      .ghpr-mini-diff {
        background: color-mix(in srgb, var(--ghpr-ink) 5%, var(--ghpr-panel));
        border: 1px solid var(--ghpr-border); border-radius: 5px; margin: 6px 0;
        max-height: 140px; overflow: auto; padding: 6px; white-space: pre-wrap;
      }
      .ghpr-finding-tools { align-items: center; display: flex; flex-wrap: wrap; gap: 6px; }
      .ghpr-insight {
        background: color-mix(in srgb, var(--ghpr-purple) 4%, var(--ghpr-panel));
        border: 1px solid var(--ghpr-border); border-radius: 7px; margin: 6px 0 0; padding: 9px;
      }
      .ghpr-insight h4 { font-size: 11px; margin: 7px 0 3px; }
      .ghpr-insight h4:first-child { margin-top: 0; }
      .ghpr-insight p { margin: 3px 0; }
      .ghpr-insight-list { margin: 3px 0 0 16px; padding: 0; }
      .ghpr-inline-marker {
        border: 0; border-radius: 999px; cursor: pointer; font: inherit;
        margin-left: 6px; padding: 2px 7px;
      }
      .ghpr-inline-panel { margin: 6px 0 8px; padding: 8px; }
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
      this.headerMenu = null;
      this.pendingSkillRuns = new Set();
      this.dismissedFindingIDs = new Set();
      this.surfaceRegistry = null;
      this.drawerHost = null;
      this.checksInsightHost = null;
      this.selectedChecksJobKey = null;
      this.filesFindingPanelMount = null;
      this.selectedFilesFindingID = null;
      this.selectedFileFindingID = null;
      this._pendingFileFindingScrollV2 = null;
      this.reviewLogRunIDV2 = null;
      this.reviewLogExpandedV2 = false;
      this.reviewStepExpandedV2 = new Map();
      this.pendingSubjectRuns = new Set();
      this.pendingExplainCIV2 = false;
      this.pendingRerunFailedCIV2 = false;
      this.operationCardSurfaceV2 = null;
      this.operationCardCollapsedV2 = false;
      this._navigatedFindingIDV2 = null;
      this._findingNavigationTimersV2 = new Map();
      this.isScrollingV2 = false;
      this.pendingRefreshAfterScrollV2 = false;
      this.scrollIdleTimerV2 = null;
      this.navigationTimerV2 = null;
      this.observerRoot = null;
      this.scheduleNavigationRefresh = null;
    }

    async start() {
      installStyles(this.document);
      const dismissed = await this.gm.getValue(STORAGE.dismissedFindings, []);
      this.dismissedFindingIDs = new Set(
        Array.isArray(dismissed) ? dismissed : []
      );
      this.gm.registerMenuCommand("Open in ghpr", () => this.openApp());
      this.gm.registerMenuCommand("Connect ghpr", async () => {
        const client = await this.bridge.pair();
        if (client) await this.refreshSafely();
      });
      this.gm.registerMenuCommand("Analyze current PR", () => {
        if (this.page?.type !== "pull_request") return;
        if (this.isSurfaceV2()) {
          this.startPRReviewV2();
        } else {
          this.invokeAction({ kind: "run_skill", skill_id: "ci.failure.classify_flaky" });
        }
      });
      this.observeNavigation();
      await this.refresh();
      return this;
    }

    stop() {
      this.stopped = true;
      if (this.timer) this.window.clearTimeout(this.timer);
      if (this.navigationTimerV2) this.window.clearTimeout(this.navigationTimerV2);
      if (this.scrollIdleTimerV2) this.window.clearTimeout(this.scrollIdleTimerV2);
      this.observer?.disconnect();
      this.observerRoot = null;
    }

    observeNavigation() {
      const schedule = () => {
        if (this.navigationTimerV2) return;
        this.navigationTimerV2 = this.window.setTimeout(() => {
          this.navigationTimerV2 = null;
          const key = `${this.window.location.pathname}${this.window.location.search}`;
          if (key !== this.navigationKey) {
            this.refreshSafely();
          } else if (this.isSurfaceV2() && !this.isScrollingV2) {
            this.renderSurfaceV2();
          }
        }, 150);
      };
      const onScroll = () => {
        if (!this.isSurfaceV2()) return;
        this.isScrollingV2 = true;
        if (this.navigationTimerV2) {
          this.window.clearTimeout(this.navigationTimerV2);
          this.navigationTimerV2 = null;
        }
        if (this.scrollIdleTimerV2) this.window.clearTimeout(this.scrollIdleTimerV2);
        this.scrollIdleTimerV2 = this.window.setTimeout(() => {
          this.scrollIdleTimerV2 = null;
          this.isScrollingV2 = false;
          if (this.pendingRefreshAfterScrollV2) {
            this.pendingRefreshAfterScrollV2 = false;
            this.refreshSafely();
          } else {
            this.renderSurfaceV2();
          }
        }, 150);
      };
      this.scheduleNavigationRefresh = schedule;
      this.observeActiveSurfaceRoot(schedule);
      this.window.addEventListener("popstate", schedule);
      this.window.addEventListener("turbo:load", schedule);
      this.window.addEventListener("turbo:render", schedule);
      this.window.addEventListener("ghpr:navigation", schedule);
      this.window.addEventListener("scroll", onScroll, { passive: true });
    }

    isManagedMutationV2(mutation) {
      const isManagedElement = (node) =>
        node?.nodeType === 1 && (
          node.matches?.(`[${MANAGED_ATTRIBUTE}], [data-ghpr-surface]`) ||
          node.closest?.(`[${MANAGED_ATTRIBUTE}], [data-ghpr-surface]`)
        );
      if (isManagedElement(mutation.target)) return true;
      const changedNodes = [
        ...(mutation.addedNodes || []),
        ...(mutation.removedNodes || [])
      ];
      return changedNodes.length > 0 && changedNodes.every((node) =>
        isManagedElement(node) || isManagedElement(node?.parentElement)
      );
    }

    observeActiveSurfaceRoot(schedule = this.scheduleNavigationRefresh) {
      if (!schedule) return;
      const useNativeSurfaceRoot = this.isSurfaceV2() ||
        this.bridge.discovery?.github_surface_v2 === true;
      const root = useNativeSurfaceRoot
        ? (this.document.querySelector("main") || this.document.body)
        : this.document.documentElement;
      if (!root || root === this.observerRoot) return;
      this.observer?.disconnect();
      this.observer = new this.window.MutationObserver((mutations) => {
        if (mutations.length && mutations.every((mutation) => this.isManagedMutationV2(mutation))) {
          return;
        }
        schedule();
      });
      this.observer.observe(root, { childList: true, subtree: true });
      this.observerRoot = root;
    }

    async refresh() {
      if (this.isSurfaceV2() && this.isScrollingV2) {
        this.pendingRefreshAfterScrollV2 = true;
        return;
      }
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
        this.snapshot = await this.bridge.request(
          "GET",
          `/api/v1/page?${query}`,
          null,
          true,
          SNAPSHOT_TIMEOUT_MS
        );
        this.render();
      } catch (error) {
        if (error.status === 401) {
          this.renderConnect();
        } else if (this.bridge.discovery?.github_surface_v2 === true) {
          this.renderSurfaceUnavailableV2(error.message);
        } else {
          this.renderTransientError(error.message);
        }
      } finally {
        this.refreshing = false;
        this.observeActiveSurfaceRoot();
        this.scheduleNextRefresh();
      }
    }

    // Timer, navigation, and observer callbacks cannot await refresh(), so a
    // throw outside its own catch — including one from its finally block —
    // would otherwise stop every later poll with no diagnostic at all.
    refreshSafely() {
      return this.refresh().catch((error) => {
        this.window.console?.error?.("[ghpr] refresh failed:", error);
        this.refreshing = false;
        try {
          this.scheduleNextRefresh();
        } catch (_) {
          // Rescheduling must never mask the failure it is recovering from.
        }
      });
    }

    // A failed page snapshot must stay visible on the GitHub-native surface.
    // Without this the userscript renders nothing at all and the failure is
    // indistinguishable from the userscript never running.
    renderSurfaceUnavailableV2(message) {
      const SR = global.GhprSurfaceRenderers;
      if (!SR) return;
      SR.installSurfaceStyles(this.document);
      this.document.getElementById(ROOT_ID)?.remove();
      this.document.getElementById(HEADER_ENTRY_ID)?.remove();
      this.renderOperationCardV2(SR, {
        unavailable: message || "ghpr could not load this pull request."
      });
    }

    scheduleNextRefresh() {
      if (this.stopped) return;
      if (this.timer) this.window.clearTimeout(this.timer);
      const active = this.snapshot?.runs?.some((run) =>
        run.status === "queued" || run.status === "running"
      );
      this.timer = this.window.setTimeout(
        () => this.refreshSafely(),
        active ? POLL_ACTIVE_MS : POLL_IDLE_MS
      );
    }

    isSurfaceV2() {
      return !!(this.snapshot && this.snapshot.github_surface_v2);
    }

    cleanupSurfaceV2() {
      this.drawerHost?.close();
      this.checksInsightHost?.close();
      this.filesFindingPanelMount?.destroy();
      this.filesFindingPanelMount = null;
      this.selectedFilesFindingID = null;
      this.surfaceRegistry?.destroyAll();
      if (this._highlightTimer) {
        this.window.clearTimeout(this._highlightTimer);
        this._highlightTimer = null;
      }
      for (const timer of this._findingNavigationTimersV2.values()) {
        this.window.clearTimeout(timer);
      }
      this._findingNavigationTimersV2.clear();
    }

    cleanup(clearSnapshot = true) {
      this.document.getElementById(ROOT_ID)?.remove();
      for (const node of this.document.querySelectorAll(`[${MANAGED_ATTRIBUTE}]`)) {
        node.remove();
      }
      this.cleanupSurfaceV2();
      if (clearSnapshot) this.snapshot = null;
      this.headerMenu = null;
    }
    headerMount() {
      const selectors = [
        "[data-testid='issue-header'] .gh-header-actions",
        "[data-testid='issue-header'] .gh-header-show",
        ".gh-header-actions",
        ".gh-header-show"
      ];
      for (const selector of selectors) {
        const host = this.document.querySelector(selector);
        if (host) return { host, before: null, floating: false };
      }

      const profileAnchor = (host) => {
        const explicit = host.querySelector(
          ".AppHeader-user, [data-testid='user-menu-button'], " +
          "[aria-label*='user navigation' i], [aria-label*='profile' i]"
        );
        if (explicit) return explicit;
        const avatar = host.querySelector("img.avatar");
        return avatar?.closest("button, details, a") || avatar;
      };
      const globalActions = this.document.querySelector(
        ".AppHeader-globalBar-end, [data-testid='app-header-global-bar-end']"
      );
      if (globalActions) {
        return {
          host: globalActions,
          before: profileAnchor(globalActions),
          floating: false
        };
      }

      const pageHeader = this.document.querySelector("header");
      const profile = pageHeader ? profileAnchor(pageHeader) : null;
      if (profile?.parentElement) {
        return { host: profile.parentElement, before: profile, floating: false };
      }
      return { host: this.document.body, before: null, floating: true };
    }

    renderHeaderEntry() {
      const mount = this.headerMount();
      if (!mount.host) return null;

      const entry = createElement(this.document, "span", {
        id: HEADER_ENTRY_ID,
        className: `ghpr-header-entry${mount.floating ? " ghpr-header-floating" : ""}`,
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "aria-label": "ghpr GitHub tools"
        }
      });
      const menu = createElement(this.document, "div", {
        className: "ghpr-header-menu",
        attributes: {
          role: "menu",
          hidden: ""
        }
      });
      const toggle = button(
        this.document,
        "ghpr ▾",
        () => {
          menu.hidden = !menu.hidden;
          toggle.setAttribute("aria-expanded", String(!menu.hidden));
        },
        "ghpr-header-button"
      );
      toggle.setAttribute("aria-haspopup", "menu");
      toggle.setAttribute("aria-expanded", "false");

      menu.append(createElement(this.document, "div", {
        className: "ghpr-header-menu-title",
        text: "ghpr"
      }));

      if (!this.snapshot) {
        menu.append(createElement(this.document, "p", {
          className: "ghpr-header-menu-summary",
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
        menu.append(connect);
      } else {
        const analysis = this.snapshot.analyses[0] || null;
        menu.append(createElement(this.document, "p", {
          className: "ghpr-header-menu-summary",
          text: analysis
            ? `${labelForVerdict(analysis.verdict)} · ${analysis.confidence} confidence`
            : "Local PR operations"
        }));


        const actions = this.panelSection("Actions");
        if (this.page?.type === "pull_request" && this.hasScope("skill:run")) {
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
          const skills = this.renderRunnableSkills();
          if (skills) actions.append(skills);
        } else if (this.page?.type === "pull_request") {
          actions.append(this.permissionPrompt(
            "Run Skills",
            "skill:run",
            "Analysis actions are off for this client."
          ));
        }
        if (actions.children.length) menu.append(actions);
        const tags = this.panelSection("Tags");
        if (this.page?.type === "pull_request" && this.hasScope("tag:write")) {
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
        } else if (this.page?.type === "pull_request") {
          tags.append(this.permissionPrompt(
            "Edit local ghpr tags",
            "tag:write",
            "Tag changes are off for this client."
          ));
        }
        if (tags.children.length) menu.append(tags);

        if (analysis && this.hasScope("detail:open")) {
          menu.append(this.panelAction("Open Full Analysis", () =>
            this.invokeAction({ kind: "open_detail", analysis_id: analysis.id })
          ));
        }
        if (this.hasScope("app:open")) {
          menu.append(this.panelAction("Open in ghpr-view", () =>
            this.invokeAction({ kind: "open_app" })
          ));
        }
        menu.append(this.panelAction("Open ghpr panel", () => {
          const root = this.document.getElementById(ROOT_ID);
          if (root) {
            root.classList.remove("ghpr-compact");
            this.panelExpanded = true;
            root.scrollIntoView?.({ behavior: "smooth", block: "nearest" });
          }
          menu.hidden = true;
          toggle.setAttribute("aria-expanded", "false");
        }));
      }

      const fallback = this.panelSection("Extensions");
      fallback.classList.add("ghpr-fallback");
      fallback.hidden = true;
      fallback.setAttribute("data-ghpr-header-fallback", "");
      menu.append(fallback);
      entry.append(toggle, menu);
      mount.host.insertBefore(entry, mount.before || null);
      this.headerMenu = menu;
      return menu;
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
      if (this.bridge.discovery && this.bridge.discovery.github_surface_v2 === true) {
        const SR = global.GhprSurfaceRenderers;
        if (!SR) return;
        SR.installSurfaceStyles(this.document);
        this.renderOperationCardV2(SR, { connected: false });
        return;
      }
      const root = this.root();
      this.renderHeaderEntry();
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
      if (this.isSurfaceV2()) {
        this.renderSurfaceV2();
        return;
      }
      this.cleanup(false);
      const root = this.root();
      this.renderHeaderEntry();
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
      if (this.page?.type === "workflow_run") this.renderWorkflowRunInsight();
      if (isFilesChangedSurface(this.window.location)) this.renderFilesFindings();
      this.renderContributions(body);
    }

    // --- GitHub-native Surface Host v2 ------------------------------------
    // Behind `snapshot.github_surface_v2`. Mounts semantic surfaces inline
    // via SurfaceMount/InlinePanelHost/DrawerHost (browser/surface-renderers.js)
    // instead of the global #ghpr-github-root card/header. Per-row Checks,
    // Actions-job, and per-line Files-changed surfaces need an exact
    // WorkflowJobSubject/DiffAnchor resolved through the Bridge subject
    // resolver; that adapter wiring extends the stub hooks below using the
    // same `this.surfaceRegistry` / `this.checksInsightHost` / `this.drawerHost`
    // instances set up here (see PLAN.md section 3-8).
    renderOperationCardV2(SR, { connected = true, unavailable = null } = {}) {
      if (this.page?.type !== "pull_request") {
        this.document.getElementById(OPERATION_CARD_ID)?.remove();
        return;
      }
      const mount = this.panelMount();
      const filesChangedCard = isFilesChangedSurface(this.window.location) && !mount.inSidebar;
      const operationCardSurface = filesChangedCard ? "files-changed" : "pull-request";
      if (operationCardSurface !== this.operationCardSurfaceV2) {
        this.operationCardSurfaceV2 = operationCardSurface;
        this.operationCardCollapsedV2 = filesChangedCard;
      }
      const cardFrame = {
        collapsible: filesChangedCard,
        collapsed: filesChangedCard && this.operationCardCollapsedV2,
        onToggle: (collapsed) => {
          this.operationCardCollapsedV2 = collapsed;
          this.renderOperationCardV2(SR, { connected, unavailable });
        }
      };
      let host = this.document.getElementById(OPERATION_CARD_ID);
      if (!host) {
        host = createElement(this.document, "div", {
          id: OPERATION_CARD_ID,
          attributes: { [MANAGED_ATTRIBUTE]: "" }
        });
      }
      host.className = [
        "ghpr-operation-card-host",
        mount.inSidebar
          ? "discussion-sidebar-item ghpr-operation-card-sidebar"
          : "ghpr-operation-card-floating",
        filesChangedCard ? "ghpr-operation-card-files" : "",
        cardFrame.collapsed ? "ghpr-operation-card-collapsed" : ""
      ].filter(Boolean).join(" ");
      if (mount.before) {
        if (host.parentElement !== mount.host || host.nextElementSibling !== mount.before) {
          mount.host.insertBefore(host, mount.before);
        }
      } else if (host.parentElement !== mount.host || host.nextElementSibling) {
        mount.host.append(host);
      }

      if (unavailable) {
        host.replaceChildren(SR.renderOperationCard(this.document, {
          ...cardFrame,
          state: "attention",
          statusLabel: "Unavailable",
          summary: unavailable,
          primaryAction: {
            id: "retry",
            label: "Retry",
            onSelect: () => this.refreshSafely()
          }
        }));
        return;
      }

      if (!connected) {
        host.replaceChildren(SR.renderOperationCard(this.document, {
          ...cardFrame,
          state: "attention",
          statusLabel: "Not connected",
          summary: "Connect the local app to review this PR.",
          primaryAction: {
            id: "connect",
            label: "Connect ghpr",
            onSelect: async () => {
              const connect = host.querySelector("[data-action-id='connect']");
              if (connect) {
                connect.disabled = true;
                connect.textContent = "Waiting for approval…";
              }
              try {
                await this.bridge.pair();
                await this.refresh();
              } catch (error) {
                if (connect) {
                  connect.disabled = false;
                  connect.textContent = "Connect ghpr";
                  connect.title = error.message;
                }
              }
            }
          }
        }));
        return;
      }

      const review = this.latestCodeReview();
      const findings = this.findingsForSurfaceV2();
      const activeReview = (this.snapshot?.runs || []).find((run) =>
        run.skill_id === "pr.review" &&
        (run.status === "queued" || run.status === "running")
      );
      const latestReviewRun = [...(this.snapshot?.runs || [])]
        .filter((run) => run.skill_id === "pr.review")
        .sort((left, right) =>
          String(right.completed_at || right.started_at || right.created_at || "")
            .localeCompare(String(left.completed_at || left.started_at || left.created_at || ""))
        )[0];
      const reviewSkill = (this.snapshot?.skills || []).find((skill) => skill.id === "pr.review");
      const agentBackend = labelForSkillAgent(
        activeReview?.agent || latestReviewRun?.agent || review?.engine || reviewSkill?.default_agent
      );
      if ((activeReview?.id || null) !== this.reviewLogRunIDV2) {
        this.reviewLogRunIDV2 = activeReview?.id || null;
        this.reviewLogExpandedV2 = false;
        this.reviewStepExpandedV2.clear();
      }
      const currentHeadSHA = this.snapshot?.current_revision_subject?.head_sha || "";
      // Retained findings carry the commit they were reviewed against even when
      // the originating run is no longer part of the snapshot.
      const reviewedHeadSHA = review?.head_sha ||
        findings.map((finding) => finding.reviewed_head_sha).find(Boolean) ||
        "";
      const reviewIsLatest = Boolean(
        reviewedHeadSHA &&
        currentHeadSHA &&
        reviewedHeadSHA.toLowerCase() === currentHeadSHA.toLowerCase()
      );
      const failedCheckCount =
        Number(this.snapshot?.pull_request?.check_failure_count || 0);
      const checksFailing = failedCheckCount > 0;
      const fileCount = new Set(
        findings.map((finding) => finding.file || finding.original_file).filter(Boolean)
      ).size;
      const explainRuns = [...(this.snapshot?.runs || [])]
        .filter((run) => run.skill_id === "ci.failure.explain")
        .sort((left, right) =>
          String(right.completed_at || right.started_at || right.created_at || "")
            .localeCompare(String(left.completed_at || left.started_at || left.created_at || ""))
        );
      const activeExplainRun = explainRuns.find((run) =>
        run.status === "queued" || run.status === "running"
      );
      const latestExplainRun = explainRuns[0] || null;
      const explainingCI = this.pendingExplainCIV2 || Boolean(activeExplainRun);
      const explainLabel = explainingCI
        ? "Explaining…"
        : latestExplainRun?.status === "completed"
          ? "Explain again"
          : ["failed", "cancelled"].includes(latestExplainRun?.status)
            ? "Retry explain"
            : "Explain CI Failure";
      const repository = this.page.repository;
      const prNumber = this.page.pr_number;
      const revisionRef = filesChangedRevisionRef(this.window.location);
      const outdatedFindings = findings.filter((finding) =>
        !finding.file || ["outdated", "unavailable"].includes(finding.lifecycle)
      );
      const actions = [];
      if (findings.length) {
        actions.push({
          id: "view-findings",
          label: "View findings",
          onSelect: () => this.navigateToFindingV2(findings[0])
        });
      }
      if (revisionRef) {
        actions.push({
          id: "back-to-latest-revision",
          label: "Back to latest revision",
          onSelect: () => {
            this.window.location.href =
              `https://github.com/${repository}/pull/${prNumber}/files`;
          }
        });
      } else if (outdatedFindings.length) {
        const reviewedRevisionURL = outdatedFindings
          .map((finding) => this.reviewedRevisionFilesURLV2(finding))
          .find(Boolean);
        if (reviewedRevisionURL) {
          actions.push({
            id: "view-reviewed-revision",
            label: "View reviewed revision",
            onSelect: () => {
              this.window.location.href = reviewedRevisionURL;
            }
          });
        }
      }
      if (checksFailing) {
        if (this.hasScope("skill:run")) {
          actions.push({
            id: "explain-ci-failure",
            label: explainLabel,
            disabled: explainingCI,
            onSelect: () => this.explainCIFailureV2(SR)
          });
          actions.push({
            id: "rerun-failed-ci",
            label: this.pendingRerunFailedCIV2 ? "Rerunning…" : "Rerun failed CI",
            disabled: this.pendingRerunFailedCIV2,
            onSelect: () => this.rerunFailedCIV2(SR)
          });
        }
        actions.push({
          id: "view-failed-checks",
          label: `Failed checks (${failedCheckCount})`,
          onSelect: () => {
            this.window.location.href =
              `https://github.com/${repository}/pull/${prNumber}/checks?ghpr_check=first`;
          }
        });
      }

      const summary = revisionRef
        ? `Findings from the reviewed revision ${revisionRef.slice(0, 7)}. The latest revision may have changed these lines.`
        : activeReview
          ? "Reviewing the exact latest revision…"
          : review
            ? reviewIsLatest
              ? "Latest revision reviewed."
              : "A newer revision is ready to review."
            : "Ready to review this revision.";
      const signals = [];
      if (agentBackend) {
        signals.push({ label: `Coding agent · ${agentBackend}`, tone: "agent" });
      }
      if (findings.length) {
        signals.push({
          label: `${findings.length} ${findings.length === 1 ? "finding" : "findings"} · ${fileCount} ${fileCount === 1 ? "file" : "files"}`
        });
      }
      if (reviewedHeadSHA) {
        signals.push({
          label: `Reviewed ${reviewedHeadSHA.slice(0, 7)}`,
          tone: reviewIsLatest ? undefined : "danger"
        });
      }
      if (!revisionRef && !reviewIsLatest && reviewedHeadSHA && currentHeadSHA) {
        signals.push({
          label: `Outdated · head ${currentHeadSHA.slice(0, 7)}`,
          tone: "danger"
        });
      }
      if (checksFailing) signals.push({ label: "Checks failing", tone: "danger" });
      const skillActions = this.hasScope("skill:run")
        ? (this.snapshot?.skills || [])
            .filter((skill) =>
              skill.is_runnable &&
              skill.id !== "pr.review" &&
              (skill.targets || []).some((target) =>
                target === "pull_request_revision" || target === "pull_request"
              )
            )
            .map((skill) => ({
              id: `run-skill-${skill.id}`,
              label: skill.display_name || skill.id,
              onSelect: () => this.startPullRequestSkillV2(skill.id)
            }))
        : [];

      host.replaceChildren(SR.renderOperationCard(this.document, {
        state: activeReview
          ? "running"
          : revisionRef || checksFailing
            ? "attention"
            : "ready",
        ...cardFrame,
        statusLabel: activeReview
          ? "Reviewing…"
          : revisionRef
            ? "Outdated revision"
            : "Ready",
        summary,
        signals,
        progressLog: activeReview ? this.reviewProgressLogModelV2(activeReview) : undefined,
        updateAction: this.updateAvailable() && this.bridge.baseURL
          ? {
              id: "update-userscript",
              label: "Update",
              onSelect: () => this.gm.openInTab(`${this.bridge.baseURL}/install/ghpr.user.js`)
            }
          : undefined,
        primaryAction: this.hasScope("skill:run") && !activeReview
          ? {
              id: "review-pr",
              label: review ? "Review latest" : "Review PR",
              onSelect: () => this.startPRReviewV2()
            }
          : activeReview
            ? {
                id: "review-pr",
                label: "Reviewing…",
                disabled: true
              }
            : undefined,
        skillActions,
        actions
      }));
    }

    async explainCIFailureV2(SR) {
      if (this.pendingExplainCIV2 || this.activeRunForSkill("ci.failure.explain")) return;
      this.pendingExplainCIV2 = true;
      this.renderOperationCardV2(SR);
      try {
        await this.invokeAction({
          kind: "run_skill",
          skill_id: "ci.failure.explain"
        });
      } finally {
        this.pendingExplainCIV2 = false;
        this.renderOperationCardV2(SR);
      }
    }

    async rerunFailedCIV2(SR) {
      if (this.pendingRerunFailedCIV2) return;
      if (!this.window.confirm("Rerun failed GitHub jobs?")) return;
      this.pendingRerunFailedCIV2 = true;
      this.renderOperationCardV2(SR);
      try {
        await this.invokeAction({ kind: "rerun_failed_jobs" });
      } finally {
        this.pendingRerunFailedCIV2 = false;
        this.renderOperationCardV2(SR);
      }
    }

    reviewProgressLogModelV2(run) {
      const supplied = Array.isArray(run.log_entries) ? run.log_entries : [];
      const inputEntries = supplied.filter((entry) => entry.stream === "skill_input");
      const outputEntries = supplied.filter((entry) => entry.stream === "agent_output");
      const receivedOutput = outputEntries.length > 0 || supplied.some((entry) =>
        entry.message === "Receiving Agent output"
      );
      const fallbackEntry = (message) => ({
        timestamp: run.started_at || run.created_at,
        kind: "running",
        message
      });
      const step = (id, label, entries, active, status) => ({
        id,
        label,
        status,
        entries: entries.length ? entries : [fallbackEntry(
          id === "executing" ? "Preparing Skill input…" : "Waiting for Agent output…"
        )],
        expanded: this.reviewStepExpandedV2.has(id)
          ? this.reviewStepExpandedV2.get(id)
          : active,
        onToggle: (expanded) => {
          this.reviewStepExpandedV2.set(id, expanded);
        }
      });
      return {
        label: "Review log",
        progressText: run.progress_message || outputEntries.at(-1)?.message,
        steps: [
          step(
            "executing",
            "Executing Skill",
            inputEntries,
            !receivedOutput,
            receivedOutput ? "success" : "running"
          ),
          step(
            "receiving-output",
            "Receiving Agent output",
            outputEntries,
            receivedOutput,
            receivedOutput ? "running" : "waiting"
          )
        ],
        expanded: this.reviewLogExpandedV2,
        onToggle: (expanded) => {
          this.reviewLogExpandedV2 = expanded;
        }
      };
    }

    renderSurfaceV2() {
      this.document.getElementById(ROOT_ID)?.remove();
      this.document.getElementById(HEADER_ENTRY_ID)?.remove();
      const SR = global.GhprSurfaceRenderers;
      if (!SR) return;
      SR.installSurfaceStyles(this.document);
      this.renderOperationCardV2(SR);
      if (!this.surfaceRegistry) this.surfaceRegistry = new SR.SurfaceRegistry({ document: this.document });
      if (!this.drawerHost) this.drawerHost = new SR.DrawerHost({ document: this.document });
      if (!this.checksInsightHost) {
        this.checksInsightHost = new SR.InlinePanelHost({
          document: this.document,
          surfaceId: SR.SURFACE_IDS.checksJobInsight
        });
      }
      if (!this.snapshot) return;

      const activeKeys = [];
      const mount = (surfaceId, host, model, viewType, opts) => {
        if (!host) return null;
        const content = this.surfaceRegistry.mount(surfaceId, host, model, viewType, opts);
        activeKeys.push(`${surfaceId}::${opts.instanceKey || "default"}`);
        return content;
      };

      this.renderConversationReviewSummaryV2(SR, mount);
      this.document.querySelector("[data-ghpr-files-review-menu]")?.remove();
      this.renderFilesTreeBadgesV2();
      // The diff-line pass resolves ?ghpr_finding= navigation, which may select
      // a file-scoped finding, so the file-level band renders after it.
      this.renderFilesDiffLineSurfacesV2(SR, mount);
      this.renderFilesFileHeadersV2(SR, mount);
      this.renderChecksSurfacesV2(SR, mount);
      this.renderActionsJobSurfaceV2(SR, mount);

      this.surfaceRegistry.unmountStale(activeKeys);
    }

    findingsForSurfaceV2() {
      return this.findingsForSnapshot(false);
    }

    // On /pull/<n>/files/<sha> the diff is the reviewed revision itself, so
    // findings reviewed against that commit are anchored with the lines they
    // were reported on instead of the lines they were remapped to.
    anchoredFindingsForSurfaceV2() {
      const revisionRef = filesChangedRevisionRef(this.window.location);
      const findings = this.findingsForSurfaceV2();
      if (!revisionRef) return findings;
      return findings.map((finding) => {
        const reviewed = String(finding.reviewed_head_sha || "").toLowerCase();
        if (!reviewed || !reviewed.startsWith(revisionRef)) return finding;
        return {
          ...finding,
          file: finding.original_file || finding.file,
          side: finding.original_side || finding.side,
          start_line: finding.original_start_line || finding.start_line,
          end_line: finding.original_end_line || finding.end_line,
          line: finding.original_end_line || finding.line,
          reviewed_revision_view: true
        };
      });
    }

    reviewedRevisionFilesURLV2(finding) {
      const repository = this.snapshot?.page?.repository || this.page?.repository;
      const prNumber = this.snapshot?.page?.pr_number || this.page?.pr_number;
      const sha = String(finding?.reviewed_head_sha || "");
      const baseSHA = String(finding?.reviewed_base_sha || "");
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository || "")) return null;
      if (!Number.isInteger(Number(prNumber)) || Number(prNumber) <= 0) return null;
      if (!/^[0-9a-f]{40}$/i.test(sha)) return null;
      // The two-dot range reproduces the whole PR diff as it stood at the
      // reviewed head; a bare head only shows that single commit.
      const revision = /^[0-9a-f]{40}$/i.test(baseSHA) ? `${baseSHA}..${sha}` : sha;
      const url = new URL(`https://github.com/${repository}/pull/${prNumber}/files/${revision}`);
      url.searchParams.set("ghpr_finding", finding.id);
      const file = finding.original_file || finding.file;
      if (file) url.searchParams.set("path", file);
      const line = finding.original_end_line || finding.end_line || finding.line;
      if (line) {
        url.searchParams.set("line", String(line));
        url.hash = `L${line}`;
      }
      return url.href;
    }

    lifecycleChipV2(finding) {
      if (finding.reviewed_revision_view) {
        return { lifecycleLabel: "Reviewed revision", lifecycleTone: "attention" };
      }
      switch (finding.lifecycle) {
        case "outdated":
        case "unavailable":
          return { lifecycleLabel: "Outdated", lifecycleTone: "danger" };
        case "remapped":
          return { lifecycleLabel: "Moved", lifecycleTone: "attention" };
        default:
          return { lifecycleLabel: undefined, lifecycleTone: undefined };
      }
    }

    buildDiffSnippetModelV2(finding) {
      if (finding.snippet?.lines?.length) return finding.snippet;
      if (!finding.quoted_code) {
        return finding.snippet?.unavailable_reason
          ? { lines: [], unavailableReason: finding.snippet.unavailable_reason }
          : null;
      }
      const sourceLines = String(finding.quoted_code).split("\n");
      const visible = sourceLines.slice(0, 7).map((text) => ({
        kind: text.startsWith("+") ? "added" : text.startsWith("-") ? "removed" : "context",
        text
      }));
      if (sourceLines.length > visible.length) visible.push({ kind: "ellipsis", text: "" });
      return { lines: visible };
    }

    buildReviewFindingModelV2(finding, { expanded = false, openInFiles = false } = {}) {
      const detailParts = [
        finding.details?.why,
        finding.details?.suggested_fix || finding.details?.suggestion,
        finding.details?.background
      ].filter(Boolean);
      const confidenceRaw = Number(finding.confidence);
      const model = {
        id: finding.id,
        title: finding.title || finding.body || finding.category || "Review finding",
        severity: finding.severity || "info",
        confidencePercent: Number.isFinite(confidenceRaw)
          ? (confidenceRaw <= 1 ? confidenceRaw * 100 : confidenceRaw)
          : undefined,
        filePath: finding.file || finding.original_file,
        startLine: finding.start_line || finding.original_start_line || finding.line,
        endLine: finding.end_line || finding.original_end_line || finding.line,
        summary: finding.summary || finding.details?.why,
        details: detailParts.length ? detailParts.join("\n\n") : finding.details_text,
        snippet: this.buildDiffSnippetModelV2(finding),
        lifecycle: finding.lifecycle,
        reviewedShortSHA: String(finding.reviewed_head_sha || "").slice(0, 7) || undefined,
        ...this.lifecycleChipV2(finding),
        expanded,
        onToggle: openInFiles
          ? () => this.navigateToFindingV2(finding)
          : () => this.openFindingsDrawerV2([finding], `finding-${finding.id}`),
        onOpenInFiles: openInFiles ? () => this.navigateToFindingV2(finding) : undefined,
        onOpenInEditor: this.editorURLV2(finding)
          ? () => this.window.open(this.editorURLV2(finding), "_blank", "noopener")
          : undefined,
        onDismiss: this.hasScope("finding:write") ? () => {
          this.dismissFinding(finding.id).then((dismissed) => {
            if (!dismissed) return;
            this.filesFindingPanelMount?.destroy();
            this.filesFindingPanelMount = null;
            this.selectedFilesFindingID = null;
            this.render();
          });
        } : undefined,
        onRequestDismissPermission: this.hasScope("finding:write")
          ? undefined
          : () => this.requestFindingWriteV2(),
        onRawDiagnostics: () => this.openApp(),
        onShowReviewedRevision: this.reviewedRevisionFilesURLV2(finding)
          ? () => {
              this.window.location.href = this.reviewedRevisionFilesURLV2(finding);
            }
          : undefined
      };
      // The copy text is derived from the very model the surface renders, so a
      // pasted finding always matches what the reader sees.
      model.onCopyFinding = () => this.copyTextV2(
        global.GhprSurfaceRenderers?.findingCopyText(model)
      );
      return model;
    }

    // Clipboard writes go through Tampermonkey first because the async
    // Clipboard API is blocked whenever the document is not focused.
    async copyTextV2(text) {
      const value = String(text || "");
      if (!value) return false;
      try {
        if (typeof this.gm.setClipboard === "function") {
          await this.gm.setClipboard(value);
          return true;
        }
      } catch {
        // fall through to the DOM clipboard paths
      }
      try {
        const clipboard = this.window.navigator?.clipboard;
        if (clipboard && typeof clipboard.writeText === "function") {
          await clipboard.writeText(value);
          return true;
        }
      } catch {
        // fall through to the execCommand path
      }
      return this.copyTextWithSelectionV2(value);
    }

    copyTextWithSelectionV2(value) {
      const document = this.document;
      if (typeof document.execCommand !== "function") return false;
      const field = document.createElement("textarea");
      field.value = value;
      field.setAttribute("aria-hidden", "true");
      field.style.position = "fixed";
      field.style.opacity = "0";
      document.body.appendChild(field);
      try {
        field.select();
        return document.execCommand("copy") === true;
      } catch {
        return false;
      } finally {
        field.remove();
      }
    }

    async requestFindingWriteV2() {
      try {
        await this.bridge.pair(
          null,
          ["finding:write"],
          this.window.location.origin === "https://github.com" ? this.window.location.href : null
        );
        await this.refresh();
      } catch (error) {
        this.renderTransientError(error.message);
      }
    }

    openFindingsDrawerV2(findings, instanceKey = "drawer", triggerEl) {
      if (!this.drawerHost) return;
      const SR = global.GhprSurfaceRenderers;
      if (!SR) return;
      const finding = findings.length === 1 ? findings[0] : null;
      const actions = [];
      const reviewedRevisionURL = finding ? this.reviewedRevisionFilesURLV2(finding) : null;
      if (reviewedRevisionURL) {
        actions.push({
          id: "view-reviewed-revision",
          label: "View reviewed revision",
          onSelect: () => {
            this.window.location.href = reviewedRevisionURL;
          }
        });
      }
      if (finding && this.page?.type === "pull_request" && this.hasScope("skill:run")) {
        actions.push({
          id: "review-latest-revision",
          label: "Review latest revision",
          onSelect: () => this.startPRReviewV2()
        });
      }
      const content = SR.renderSurface(this.document, "detail_drawer", {
        title: finding
          ? (finding.title || finding.body || finding.category || "Finding")
          : "ghpr findings",
        subtitle: finding
          ? [
              finding.file || finding.original_file,
              finding.lifecycle,
              finding.reviewed_head_sha ? `reviewed ${finding.reviewed_head_sha.slice(0, 7)}` : null
            ].filter(Boolean).join(" · ")
          : `${findings.length} findings`,
        sections: findings.map((item) => ({
          heading: item.file || item.original_file || "Finding",
          body: SR.renderReviewFinding(this.document, this.buildReviewFindingModelV2(item, { expanded: true }))
        })),
        actions
      });
      content.dataset.ghprInstance = instanceKey;
      this.drawerHost.open(content, { triggerEl });
    }

    reportSurfaceHealthV2(surface, state, detail) {
      if (!surface || !this.hasScope("ui:contribute")) return;
      this._surfaceHealthV2 = this._surfaceHealthV2 || new Map();
      const signature = `${state}:${detail || ""}`;
      if (this._surfaceHealthV2.get(surface) === signature) return;
      this._surfaceHealthV2.set(surface, signature);
      this.bridge.request("POST", "/api/v1/surface-health", {
        surface,
        state,
        detail: detail || null
      }).catch(() => {});
    }

    renderConversationReviewSummaryV2(SR, mount) {
      if (!isConversationSurface(this.window.location)) return;
      const anchors = semanticTargets(this.document, "pr.conversation.after-checks");
      const health = anchors.length === 1 ? "healthy" : anchors.length === 0 ? "missing" : "ambiguous";
      this.reportSurfaceHealthV2(
        SR.SURFACE_IDS.conversationReviewSummary,
        health,
        health === "healthy" ? "Conversation timeline anchor found." : `Expected one Conversation timeline anchor; found ${anchors.length}.`
      );
      if (anchors.length !== 1) return;
      const anchor = anchors[0];
      const review = this.latestCodeReview();
      const findings = this.findingsForSurfaceV2();
      const activeReview = (this.snapshot.runs || []).find((run) =>
        run.skill_id === "pr.review" &&
        (run.status === "queued" || run.status === "running")
      );
      const reviewedHeadSHA = review?.head_sha || "";
      const reviewedShortSHA = reviewedHeadSHA.slice(0, 7);
      const currentHeadSHA = this.snapshot?.current_revision_subject?.head_sha || "";
      const isLatest = Boolean(
        reviewedHeadSHA &&
        currentHeadSHA &&
        reviewedHeadSHA.toLowerCase() === currentHeadSHA.toLowerCase()
      );
      const revisionText = activeReview
        ? "Reviewing the exact latest revision…"
        : review
          ? `Reviewed revision ${reviewedShortSHA}${isLatest ? " (latest)" : ""}`
          : "Ready to review the exact latest revision";
      const findingModels = findings.map((finding, index) =>
        this.buildReviewFindingModelV2(finding, {
          expanded: index === 0,
          openInFiles: true
        })
      );
      const summaryModel = {
        reviewedShortSHA,
        isLatest,
        revisionText,
        findingCount: findings.length,
        fileCount: new Set(findings.map((finding) => finding.file)).size,
        findings: findingModels
      };
      mount(
        SR.SURFACE_IDS.conversationReviewSummary,
        anchor.parentNode,
        {
          ...summaryModel,
          onCopyAll: findings.length
            ? () => this.copyTextV2(SR.reviewSummaryCopyText(summaryModel))
            : undefined,
          onUpdate: this.updateAvailable() && this.bridge.baseURL
            ? () => this.gm.openInTab(`${this.bridge.baseURL}/install/ghpr.user.js`)
            : undefined,
          updateLabel: "Update ghpr userscript",
          onOpenInFiles: findings.length
            ? () => this.navigateToFindingV2(findings[0])
            : undefined,
          onReview: this.hasScope("skill:run") && !activeReview
            ? () => this.startPRReviewV2()
            : undefined,
          reviewLabel: review ? "Review latest" : "Review PR",
          reviewDisabled: Boolean(activeReview)
        },
        "review_summary",
        { instanceKey: "default", anchor, position: "after" }
      );
    }


    renderFilesTreeBadgesV2() {
      const selector = "[data-ghpr-file-tree-badge]";
      if (!isFilesChangedSurface(this.window.location)) {
        for (const badge of this.document.querySelectorAll(selector)) badge.remove();
        return;
      }
      const countsByFile = new Map();
      for (const finding of this.anchoredFindingsForSurfaceV2()) {
        const path = this.normalizeDiffPathV2(finding.file || finding.original_file);
        if (!path) continue;
        countsByFile.set(path, (countsByFile.get(path) || 0) + 1);
      }
      for (const item of semanticTargets(this.document, "files.tree.file")) {
        const fileLink = item.querySelector("a[href^='#diff-']");
        const content = fileLink?.parentElement?.parentElement;
        const path = this.normalizeDiffPathV2(item.id);
        const count = countsByFile.get(path) || 0;
        let badge = item.querySelector(selector);
        if (!fileLink || !content || !count) {
          badge?.remove();
          continue;
        }
        const label = `${count} ghpr ${count === 1 ? "comment" : "comments"}`;
        if (!badge) {
          badge = createElement(this.document, "span", {
            className: "ghpr-file-tree-badge",
            attributes: {
              [MANAGED_ATTRIBUTE]: "",
              "data-ghpr-file-tree-badge": ""
            }
          });
          content.append(badge);
        }
        badge.textContent = String(count);
        badge.setAttribute("aria-label", label);
        badge.title = label;
      }
    }

    normalizeDiffPathV2(value) {
      return String(value || "")
        .replace(/[\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
        .trim();
    }

    diffContainerPathV2(container) {
      if (!container) return null;
      const explicit = container.getAttribute("data-tagsearch-path")
        || container.getAttribute("data-path")
        || container.querySelector("[data-path]")?.getAttribute("data-path");
      const headerPath = container.querySelector("[data-diff-header-wrapper] h3 code")?.textContent;
      return this.normalizeDiffPathV2(explicit || headerPath) || null;
    }

    diffContainersV2() {
      return [
        ...this.document.querySelectorAll(
          "[data-tagsearch-path], .file[data-path], [role='region'][id^='diff-']"
        )
      ];
    }

    diffContainerForFindingV2(finding) {
      const paths = [finding?.file, finding?.original_file]
        .map((path) => this.normalizeDiffPathV2(path))
        .filter(Boolean);
      if (!paths.length) return null;
      return this.diffContainersV2()
        .find((container) => paths.includes(this.diffContainerPathV2(container))) || null;
    }

    diffTableForFindingV2(finding) {
      return this.diffContainerForFindingV2(finding)
        ?.querySelector("table.diff-table, table[data-diff-anchor]") || null;
    }

    renderFilesFileHeadersV2(SR, mount) {
      if (!isFilesChangedSurface(this.window.location)) return;
      const fileTables = semanticTargets(this.document, "files.diff.line-decoration");
      this.reportSurfaceHealthV2(
        SR.SURFACE_IDS.filesFileHeader,
        fileTables.length ? "healthy" : "missing",
        fileTables.length ? "Files diff hosts found." : "No loaded Files diff host was found."
      );
      const findings = this.anchoredFindingsForSurfaceV2();
      if (!findings.length) return;
      const byFile = new Map();
      for (const finding of findings) {
        const path = finding.file || finding.original_file;
        // File-scoped means the finding has no diff line to sit on at all. A
        // line-anchored finding whose row is not rendered yet (collapsed or
        // lazy-loaded diff) stays pending for the diff-line pass instead of
        // being relabelled as file-level.
        if (!path || finding.line) continue;
        if (!byFile.has(path)) byFile.set(path, []);
        byFile.get(path).push(finding);
      }
      for (const table of fileTables) {
        const container = table.closest(
          "[data-tagsearch-path], .file[data-path], [role='region'][id^='diff-']"
        );
        const path = this.diffContainerPathV2(container);
        const fileFindings = path ? byFile.get(path) : undefined;
        if (!fileFindings?.length) continue;
        for (const finding of fileFindings) {
          const expanded = finding.id === this.selectedFileFindingID;
          const model = expanded
            ? {
                ...this.buildReviewFindingModelV2(finding, { expanded: true }),
                fileLevel: true,
                onCollapse: () => {
                  this.selectedFileFindingID = null;
                  this.render();
                }
              }
            : {
                ...this.buildReviewFindingModelV2(finding),
                fileLevel: true,
                showSummary: true,
                snippet: null,
                onToggle: () => {
                  this.selectedFileFindingID = finding.id;
                  this.render();
                }
              };
          const content = mount(
            SR.SURFACE_IDS.filesFileHeader,
            table.parentNode,
            model,
            expanded ? "review_finding" : "review_finding_preview",
            {
              instanceKey: `${path}#${finding.id}`,
              subjectKey: finding.id,
              anchor: table,
              position: "before"
            }
          );
          if (content) content.dataset.ghprFindingScope = "file";
          if (content && this._pendingFileFindingScrollV2 === finding.id) {
            this._pendingFileFindingScrollV2 = null;
            content.scrollIntoView?.({ block: "center" });
          }
        }
      }
    }

    renderFilesDiffLineSurfacesV2(SR, mount) {
      if (!isFilesChangedSurface(this.window.location)) return;
      const lineHosts = semanticTargets(this.document, "files.diff.line-decoration");
      this.reportSurfaceHealthV2(
        SR.SURFACE_IDS.filesDiffLineAfter,
        lineHosts.length ? "healthy" : "missing",
        lineHosts.length ? "Files line hosts found." : "No loaded Files line host was found."
      );
      const allFindings = this.anchoredFindingsForSurfaceV2();
      const findings = allFindings.filter((finding) => finding.file && finding.line);
      const groups = new Map();
      for (const finding of findings) {
        const row = this.locateDiffRowV2(finding);
        if (!row) continue;
        const cell = this.locateDiffCellV2(row, finding);
        if (!cell) continue;
        const side = finding.side === "left" || finding.side === "deletion" ? "left" : "right";
        const key = `${finding.file}:${side}:${finding.line}`;
        if (!groups.has(key)) groups.set(key, { row, cell, findings: [] });
        groups.get(key).findings.push(finding);
      }
      for (const [key, group] of groups) {
        for (const finding of group.findings) {
          const ordered = [finding, ...group.findings.filter((item) => item !== finding)];
          mount(
            SR.SURFACE_IDS.filesDiffLineAfter,
            group.cell,
            {
              ...this.buildReviewFindingModelV2(finding, {
                expanded: finding.id === this.selectedFilesFindingID
              }),
              inline: true,
              showSummary: true,
              snippet: null,
              locationLabel: this.findingAnchorLabelV2(finding),
              onToggle: (_id, element) => this.openInlineFindingPanelV2(
                SR,
                group.row,
                ordered,
                element
              )
            },
            "review_finding_preview",
            { instanceKey: `${key}#${finding.id}`, subjectKey: finding.id, position: "append" }
          );
        }
      }
      this.handleFindingNavigationV2(SR, allFindings);
    }

    findingAnchorLabelV2(finding) {
      const start = Number(finding.start_line || finding.original_start_line || finding.line);
      const end = Number(finding.end_line || finding.original_end_line || finding.line);
      const parts = [];
      if (Number.isFinite(start) && start > 0) {
        parts.push(Number.isFinite(end) && end > start ? `L${start}-L${end}` : `L${start}`);
      }
      const reviewed = String(finding.reviewed_head_sha || "").slice(0, 7);
      if (reviewed) parts.push(reviewed);
      return parts.join(" · ");
    }

    openInlineFindingPanelV2(SR, row, findings, triggerEl) {
      this.drawerHost?.close();
      if (!row?.parentNode || !findings.length) return;
      this.filesFindingPanelMount?.destroy();
      const selected = findings[0];
      this.selectedFilesFindingID = selected.id;
      const allFindings = this.anchoredFindingsForSurfaceV2();
      const selectedIndex = allFindings.findIndex((finding) => finding.id === selected.id);
      const panel = this.document.createElement("div");
      panel.className = "ghpr-inline-finding-card";
      panel.dataset.testid = "ghpr-inline-finding-panel";
      if (selectedIndex >= 0) {
        panel.append(SR.renderItemNavigator(this.document, {
          position: selectedIndex + 1,
          total: allFindings.length,
          noun: allFindings.length === 1 ? "finding" : "findings",
          ariaLabel: "Review findings navigation",
          previousID: "previous-finding",
          nextID: "next-finding",
          onPrevious: selectedIndex > 0
            ? () => this.selectFindingInFilesV2(SR, allFindings[selectedIndex - 1])
            : undefined,
          onNext: selectedIndex + 1 < allFindings.length
            ? () => this.selectFindingInFilesV2(SR, allFindings[selectedIndex + 1])
            : undefined
        }));
      }
      for (const finding of findings) {
        panel.append(SR.renderReviewFinding(
          this.document,
          this.buildReviewFindingModelV2(finding, { expanded: true })
        ));
      }
      const cell = this.document.createElement("td");
      cell.colSpan = Math.max(row.children.length, 1);
      cell.append(panel);
      const panelRow = this.document.createElement("tr");
      panelRow.className = "ghpr-inline-finding-row";
      panelRow.append(cell);
      this.filesFindingPanelMount = new SR.SurfaceMount({
        document: this.document,
        surfaceId: SR.SURFACE_IDS.filesDiffLineAfter,
        host: row.parentNode,
        anchor: row,
        position: "after",
        instanceKey: `panel-${selected.id}`,
        subjectKey: selected.id
      });
      this.filesFindingPanelMount.mount(panelRow);
      for (const preview of this.document.querySelectorAll(
        ".ghpr-review-finding-preview[data-inline='true']"
      )) {
        const isSelected = preview.getAttribute("data-ghpr-subject-key") === selected.id;
        preview.setAttribute("data-expanded", isSelected ? "true" : "false");
        preview.setAttribute("aria-expanded", isSelected ? "true" : "false");
      }
      if (triggerEl) {
        triggerEl.setAttribute("aria-expanded", "true");
        if (triggerEl.hasAttribute?.("data-expanded")) {
          triggerEl.setAttribute("data-expanded", "true");
        }
      }
    }

    selectFindingInFilesV2(SR, finding) {
      if (!finding) return;
      const url = new URL(this.window.location.href);
      url.searchParams.set("ghpr_finding", finding.id);
      this.window.history.replaceState({}, "", url);
      this._navigatedFindingIDV2 = null;
      this.handleFindingNavigationV2(SR, this.anchoredFindingsForSurfaceV2());
    }

    locateDiffRowV2(finding) {
      const table = this.diffTableForFindingV2(finding);
      if (!table) return null;
      const line = String(finding.line);
      const isLeft = finding.side === "left" || finding.side === "deletion";
      const modernSide = isLeft ? "left" : "right";
      const modernCell = table.querySelector(
        `td[data-line-anchor][data-diff-side="${modernSide}"][data-line-number="${line}"]`
      );
      if (modernCell) return modernCell.closest("tr");
      const legacySide = isLeft ? "deletion" : "addition";
      const numberCell = table.querySelector(
        `td.blob-num-${legacySide}[data-line-number="${line}"]`
      );
      return numberCell?.closest("tr") || null;
    }

    locateDiffCellV2(row, finding) {
      const isLeft = finding.side === "left" || finding.side === "deletion";
      const modernSide = isLeft ? "left" : "right";
      return row.querySelector(`td[data-line-anchor][data-diff-side="${modernSide}"]`)
        || row.querySelector(`.blob-code-${isLeft ? "deletion" : "addition"}`);
    }

    handleFindingNavigationV2(SR, findings) {
      const params = new URLSearchParams(this.window.location.search);
      const findingID = params.get("ghpr_finding");
      if (!findingID) {
        this._navigatedFindingIDV2 = null;
        for (const timer of this._findingNavigationTimersV2.values()) {
          this.window.clearTimeout(timer);
        }
        this._findingNavigationTimersV2.clear();
        return;
      }
      if (this._navigatedFindingIDV2 === findingID) return;
      const finding = findings.find((item) => item.id === findingID);
      if (!finding) {
        this._navigatedFindingIDV2 = findingID;
        this.openFindingsDrawerV2([], "finding-missing");
        return;
      }
      // No diff line at all: the finding belongs to the file-level band when its
      // file is on this page, and to the drawer when the file is not.
      if (!finding.line || !(finding.file || finding.original_file)) {
        this._navigatedFindingIDV2 = findingID;
        if (this.diffTableForFindingV2(finding)) {
          this.selectedFileFindingID = finding.id;
          this._pendingFileFindingScrollV2 = finding.id;
          return;
        }
        this.openFindingsDrawerV2([finding], `finding-${finding.id}`);
        return;
      }
      const fileContainer = this.diffContainerForFindingV2(finding);
      const disclosure = fileContainer?.querySelector("button[aria-expanded='false'], summary");
      disclosure?.click();
      const row = this.locateDiffRowV2(finding);
      if (!row) {
        if (!this._findingNavigationTimersV2.has(findingID)) {
          const timer = this.window.setTimeout(() => {
            this._findingNavigationTimersV2.delete(findingID);
            if (this._navigatedFindingIDV2 === findingID) return;
            this._navigatedFindingIDV2 = findingID;
            this.openFindingsDrawerV2([finding], `finding-${finding.id}`);
          }, 10_000);
          this._findingNavigationTimersV2.set(findingID, timer);
        }
        return;
      }
      const navigationTimer = this._findingNavigationTimersV2.get(findingID);
      if (navigationTimer) this.window.clearTimeout(navigationTimer);
      this._findingNavigationTimersV2.delete(findingID);
      this._navigatedFindingIDV2 = findingID;
      this.openInlineFindingPanelV2(SR, row, [finding]);
      row.scrollIntoView?.({ block: "center" });
      const highlightedRows = [];
      const startLine = Number(finding.start_line || finding.line);
      const endLine = Number(finding.end_line || finding.line);
      for (let line = startLine; line <= endLine; line += 1) {
        const target = this.locateDiffRowV2({ ...finding, line });
        if (target && !highlightedRows.includes(target)) highlightedRows.push(target);
      }
      for (const target of highlightedRows) target.classList.add("ghpr-v2-highlight");
      [...this.document.querySelectorAll("[data-finding-id]")]
        .find((element) => element.getAttribute("data-finding-id") === finding.id)
        ?.querySelector(".ghpr-review-finding-title")
        ?.focus();
      if (this._highlightTimer) this.window.clearTimeout(this._highlightTimer);
      this._highlightTimer = this.window.setTimeout(() => {
        for (const target of highlightedRows) target.classList.remove("ghpr-v2-highlight");
        this._highlightTimer = null;
      }, 2000);
    }

    navigateToFindingV2(finding) {
      if (!finding) return;
      const repo = this.snapshot?.page?.repository || this.page?.repository;
      const number = this.snapshot?.page?.pr_number || this.page?.pr_number;
      try {
        this.window.sessionStorage?.setItem(`ghpr.finding.${repo}#${number}`, finding.id);
      } catch (_) {
        // Session storage may be unavailable; the query param still carries the finding ID.
      }
      const href = this.findingURL(finding);
      if (href) this.window.location.href = href;
    }

    subjectKeyForWorkflowJob(subject) {
      const repository = String(subject.repository).toLowerCase();
      const runID = subject.workflow_run_id;
      const jobID = subject.workflow_job_id;
      if (subject.workflow_attempt && subject.head_sha) {
        return `github:workflow-job:${repository}:run:${runID}:attempt:${subject.workflow_attempt}:job:${jobID}@${subject.head_sha}`;
      }
      return workflowJobSubjectKey({ repository, runId: runID, jobId: jobID });
    }

    latestRunForSubjectV2(skillID, subject) {
      return [...(this.snapshot?.runs || [])]
        .filter((run) => {
          if (run.skill_id !== skillID) return false;
          const runSubject = run.subject;
          if (runSubject?.type === "workflow_job") {
            return String(runSubject.workflow_run_id) === String(subject.workflow_run_id) &&
              String(runSubject.workflow_job_id) === String(subject.workflow_job_id);
          }
          return run.subject_key === this.subjectKeyForWorkflowJob(subject);
        })
        .sort((left, right) =>
          String(right.completed_at || right.started_at || "").localeCompare(String(left.completed_at || left.started_at || ""))
        )[0] || null;
    }

    async resolveWorkflowJobSubjectV2(subject) {
      if (subject.workflow_attempt && subject.head_sha) return subject;
      const resolved = await this.bridge.request(
        "POST",
        "/api/v1/subjects/resolve",
        {
          type: "workflow_job",
          repository: subject.repository,
          workflow_job_id: subject.workflow_job_id
        }
      );
      return {
        type: "workflow_job",
        repository: resolved.repository,
        workflow_run_id: resolved.workflow_run_id,
        workflow_attempt: resolved.workflow_attempt,
        workflow_job_id: resolved.workflow_job_id,
        head_sha: resolved.head_sha
      };
    }

    async startPRReviewV2() {
      return this.startPullRequestSkillV2("pr.review");
    }

    async startPullRequestSkillV2(skillID) {
      if (!this.page?.repository || !this.page?.pr_number) return;
      const pendingKey = `${skillID}::${this.page.key}`;
      if (this.pendingSubjectRuns.has(pendingKey)) return;
      this.pendingSubjectRuns.add(pendingKey);
      try {
        const revision = await this.bridge.request(
          "POST",
          "/api/v1/subjects/resolve",
          {
            type: "pull_request_revision",
            repository: this.page.repository,
            pr_number: this.page.pr_number
          }
        );
        const subject = {
          type: "pull_request_revision",
          repository: revision.repository,
          pr_number: revision.pr_number,
          base_sha: revision.base_sha,
          head_sha: revision.head_sha
        };
        const alreadyReviewed = skillID === "pr.review" &&
          (this.snapshot?.runs || []).some((run) => {
            const codeReview = run.result?.code_review;
            if (!codeReview) return false;
            const reviewedHeadSHA = codeReview.head_sha || run.subject?.head_sha;
            return reviewedHeadSHA &&
              reviewedHeadSHA.toLowerCase() === revision.head_sha.toLowerCase();
          });
        if (
          alreadyReviewed &&
          !this.window.confirm(
            `Revision ${revision.head_sha.slice(0, 7)} has already been reviewed. Review it again?`
          )
        ) {
          this.pendingSubjectRuns.delete(pendingKey);
          return;
        }
        const subjectKey = [
          "github:pull-request-revision:",
          revision.repository.toLowerCase(),
          "#",
          revision.pr_number,
          "@",
          revision.base_sha,
          "..",
          revision.head_sha
        ].join("");
        this.pendingSubjectRuns.delete(pendingKey);
        this.runSkillForSubjectV2(skillID, subject, subjectKey);
      } catch (error) {
        this.renderTransientError(error.message);
        this.pendingSubjectRuns.delete(pendingKey);
      }
    }

    async runSkillForSubjectV2(skillID, subject, subjectKey) {
      const pendingKey = `${skillID}::${subjectKey}`;
      if (this.pendingSubjectRuns.has(pendingKey)) return;
      const active = this.latestRunForSubjectV2(skillID, subject);
      if (active && (active.status === "queued" || active.status === "running")) return;
      this.pendingSubjectRuns.add(pendingKey);
      try {
        const exactSubject = subject.type === "workflow_job"
          ? await this.resolveWorkflowJobSubjectV2(subject)
          : subject;
        const response = await this.bridge.request("POST", "/api/v1/actions", {
          action: { kind: "run_skill", skill_id: skillID, subject: exactSubject },
          page: this.page,
          confirmed: false
        });
        this.openResponseURL(response);
        await this.refresh();
      } catch (error) {
        this.renderTransientError(error.message);
      } finally {
        this.pendingSubjectRuns.delete(pendingKey);
      }
    }

    openRunDrawerV2(run) {
      if (!this.drawerHost) return;
      const SR = global.GhprSurfaceRenderers;
      if (!SR) return;
      const content = SR.renderSurface(this.document, "detail_drawer", {
        title: run.skill_id,
        subtitle: run.status,
        raw: JSON.stringify(run.result || {}, null, 2)
      });
      this.drawerHost.open(content);
    }

    buildCiInsightModelV2(subject) {
      const explainRun = this.latestRunForSubjectV2("ci.failure.explain", subject);
      const classifyRun = this.latestRunForSubjectV2("ci.failure.classify_flaky", subject);
      const section = (run, kind) => {
        if (!run) return { status: "unavailable" };
        if (run.status === "queued" || run.status === "running") return { status: "running" };
        if (run.status !== "completed" || !run.result?.payload ||
            typeof run.result.payload !== "object") {
          return { status: "unavailable" };
        }
        const payload = run.result.payload;
        if (kind === "explain") {
          return {
            status: "ready",
            whyItFailed: payload.why_it_failed,
            relevantEvidence: Array.isArray(payload.relevant_evidence)
              ? payload.relevant_evidence
              : [],
            suggestedAction: payload.suggested_action,
            onViewFullResult: () => this.openRunDrawerV2(run)
          };
        }
        const confidenceRaw = Number(payload.confidence);
        const payloadHistory = payload.history && typeof payload.history === "object"
          ? payload.history
          : undefined;
        return {
          status: "ready",
          verdict: labelForVerdict(payload.verdict),
          confidencePercent: Number.isFinite(confidenceRaw)
            ? (confidenceRaw <= 1 ? confidenceRaw * 100 : confidenceRaw)
            : undefined,
          flakyEvidence: Array.isArray(payload.flaky_evidence)
            ? payload.flaky_evidence
            : [],
          history: payloadHistory
            ? {
                failedRuns: payloadHistory.failed_runs,
                totalRuns: payloadHistory.total_runs,
                windowDays: payloadHistory.window_days
              }
            : undefined,
          reproduction: payload.reproduction,
          suggestedAction: payload.suggested_action,
          onViewFullResult: () => this.openRunDrawerV2(run)
        };
      };
      return {
        explain: section(explainRun, "explain"),
        classify: section(classifyRun, "classify")
      };
    }
    checksInsightModelV2(subject, row) {
      const model = this.buildCiInsightModelV2(subject);
      const jobLink = row?.querySelector("a[href*='/actions/runs/']");
      model.explain = {
        ...(model.explain || {}),
        actions: [
          ...((model.explain && model.explain.actions) || []),
          ...(model.explain?.status !== "running"
            ? [{
                id: "explain",
                label: model.explain?.status === "ready" ? "Explain again" : "Explain CI Failure",
                onSelect: () => this.runSkillForSubjectV2(
                  "ci.failure.explain",
                  subject,
                  this.subjectKeyForWorkflowJob(subject)
                )
              }]
            : []),
          ...(jobLink
            ? [{ id: "inspect", label: "Inspect job", onSelect: () => jobLink.click() }]
            : []),
          {
            id: "rerun",
            label: "Re-run failed job",
            onSelect: () => this.invokeAction({ kind: "rerun_failed_jobs" }, true)
          }
        ]
      };
      model.classify = {
        ...(model.classify || {}),
        actions: [
          ...((model.classify && model.classify.actions) || []),
          ...(model.classify?.status !== "running"
            ? [{
                id: "classify",
                label: model.classify?.status === "ready" ? "Classify again" : "Classify Flaky",
                onSelect: () => this.runSkillForSubjectV2(
                  "ci.failure.classify_flaky",
                  subject,
                  this.subjectKeyForWorkflowJob(subject)
                )
              }]
            : [])
        ]
      };
      return model;
    }


    selectChecksJobV2(SR, jobs, index, { scroll = true, updateURL = true } = {}) {
      const selected = jobs[index];
      if (!selected) return;
      this.selectedChecksJobKey = selected.subjectKey;
      if (updateURL) {
        const url = new URL(this.window.location.href);
        url.searchParams.set("ghpr_check", selected.subjectKey);
        this.window.history.replaceState({}, "", url);
      }
      const model = this.checksInsightModelV2(selected.subject, selected.row);
      model.navigation = {
        position: index + 1,
        total: jobs.length,
        noun: jobs.length === 1 ? "failed check" : "failed checks",
        ariaLabel: "Failed checks navigation",
        previousID: "previous-failed-check",
        nextID: "next-failed-check",
        onPrevious: index > 0
          ? () => this.selectChecksJobV2(SR, jobs, index - 1)
          : undefined,
        onNext: index + 1 < jobs.length
          ? () => this.selectChecksJobV2(SR, jobs, index + 1)
          : undefined
      };
      const content = SR.renderSurface(this.document, "ci_insight", model);
      this.checksInsightHost.openAfter(selected.row, content, {
        subjectKey: selected.subjectKey,
        instanceKey: "panel"
      });
      if (scroll) selected.row.scrollIntoView?.({ block: "center" });
    }

    renderChecksSurfacesV2(SR, mount) {
      if (!isChecksSurface(this.window.location)) return;
      const rows = semanticTargets(this.document, "checks.run.trailing");
      this.reportSurfaceHealthV2(
        SR.SURFACE_IDS.checksJobTrailing,
        rows.length ? "healthy" : "missing",
        rows.length ? "Checks rows found." : "No native Checks rows were found."
      );
      const failedJobs = [];
      for (const row of rows) {
        if (!/\b(failed|failure)\b/i.test(row.textContent || "")) continue;
        const link = row.querySelector("a[href*='/actions/runs/']");
        const parsed = link ? parseWorkflowJobHref(link.getAttribute("href")) : null;
        if (!parsed) continue;
        const subject = {
          type: "workflow_job",
          repository: parsed.repository,
          workflow_run_id: Number(parsed.runId),
          workflow_job_id: Number(parsed.jobId)
        };
        failedJobs.push({
          row,
          subject,
          subjectKey: this.subjectKeyForWorkflowJob(subject)
        });
      }

      const requestedCheck = new URLSearchParams(this.window.location.search).get("ghpr_check");
      if (requestedCheck && failedJobs.length) {
        const requestedIndex = requestedCheck === "first"
          ? 0
          : failedJobs.findIndex((job) => job.subjectKey === requestedCheck);
        if (requestedIndex >= 0) this.selectedChecksJobKey = failedJobs[requestedIndex].subjectKey;
      }

      let selectedRowStillPresent = false;
      for (const [index, job] of failedJobs.entries()) {
        const { row, subject, subjectKey } = job;
        const explainRun = this.latestRunForSubjectV2("ci.failure.explain", subject);
        const classifyRun = this.latestRunForSubjectV2("ci.failure.classify_flaky", subject);
        const activeRun = [explainRun, classifyRun].find((run) => run && (run.status === "queued" || run.status === "running"));
        const completedRun = [classifyRun, explainRun].find((run) => run && run.status === "completed" && run.result);
        const failedRun = [classifyRun, explainRun].find((run) => run && (run.status === "failed" || run.status === "cancelled"));
        let status = "idle";
        let confidencePercent;
        const actions = [];
        if (activeRun) {
          status = "running";
          actions.push({ id: "cancel", label: "Cancel", onSelect: () => this.invokeAction({ kind: "cancel_run", run_id: activeRun.id }) });
        } else if (completedRun) {
          const payload = completedRun.result.payload || {};
          status = payload.verdict || "needs_investigation";
          const confidenceRaw = Number(payload.confidence);
          confidencePercent = Number.isFinite(confidenceRaw) ? (confidenceRaw <= 1 ? confidenceRaw * 100 : confidenceRaw) : undefined;
          actions.push(
            { id: "explain", label: "Explain", onSelect: () => this.selectChecksJobV2(SR, failedJobs, index) },
            { id: "rerun", label: "Re-run", onSelect: () => this.runSkillForSubjectV2("ci.failure.classify_flaky", subject, subjectKey) }
          );
        } else if (failedRun) {
          status = "failed";
          actions.push({ id: "retry", label: "Retry", onSelect: () => this.runSkillForSubjectV2(failedRun.skill_id, subject, subjectKey) });
        } else {
          actions.push({ id: "explain", label: "Explain", onSelect: () => this.selectChecksJobV2(SR, failedJobs, index) });
        }
        mount(
          SR.SURFACE_IDS.checksJobTrailing,
          row,
          { status, confidencePercent, actions },
          "job_verdict",
          { instanceKey: subjectKey, subjectKey, position: "append" }
        );
        if (this.selectedChecksJobKey === subjectKey) {
          selectedRowStillPresent = true;
          this.selectChecksJobV2(SR, failedJobs, index, {
            scroll: false,
            updateURL: false
          });
        }
      }
      if (!selectedRowStillPresent && this.checksInsightHost?.isOpen) {
        this.checksInsightHost.close();
        this.selectedChecksJobKey = null;
      }
    }

    revealNativeLogsV2() {
      const logs = this.document.querySelector("[data-testid='logs-region']");
      if (!logs) return;
      logs.hidden = false;
      logs.removeAttribute("hidden");
      logs.scrollIntoView?.({ block: "center" });
    }

    renderActionsJobSurfaceV2(SR, mount) {
      const parsed = parseWorkflowJobHref(this.window.location.pathname);
      if (!parsed) return;
      const subject = {
        type: "workflow_job",
        repository: parsed.repository,
        workflow_run_id: Number(parsed.runId),
        workflow_job_id: Number(parsed.jobId)
      };
      const subjectKey = this.subjectKeyForWorkflowJob(subject);
      const failureSummaries = [...this.document.querySelectorAll("[data-testid='failure-summary']")];
      const health = failureSummaries.length === 1 ? "healthy" : failureSummaries.length === 0 ? "missing" : "ambiguous";
      this.reportSurfaceHealthV2(
        SR.SURFACE_IDS.actionsJobAfterFailureSummary,
        health,
        health === "healthy" ? "Actions failure summary found." : `Expected one Actions failure summary; found ${failureSummaries.length}.`
      );
      if (failureSummaries.length !== 1) return;
      const failureSummary = failureSummaries[0];
      const host = failureSummary.parentElement;
      if (!host) return;
      const model = this.checksInsightModelV2(subject, null);
      model.surfaceMode = "actions_job";
      model.jobName = this.document.querySelector("[data-testid='job-title']")?.textContent?.trim()
        || this.document.querySelector("h1")?.textContent?.trim()
        || undefined;
      model.classify = {
        ...(model.classify || {}),
        actions: [
          ...((model.classify && model.classify.actions) || []),
          { id: "logs", label: "View raw logs", onSelect: () => this.revealNativeLogsV2() }
        ]
      };
      mount(
        SR.SURFACE_IDS.actionsJobAfterFailureSummary,
        host,
        model,
        "ci_insight",
        {
          instanceKey: subjectKey,
          subjectKey,
          anchor: failureSummary || undefined,
          position: failureSummary ? "after" : "append"
        }
      );
    }

    renderPanel() {
      const panel = createElement(this.document, "div", {
        className: "ghpr-panel-body"
      });
      const updateNotice = this.renderUpdateNotice();
      if (updateNotice) panel.append(updateNotice);
      const analysis = this.snapshot.analyses[0] || null;
      const actions = this.panelSection("Actions");
      if (this.page?.type === "pull_request" && this.hasScope("skill:run")) {
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
        const skills = this.renderRunnableSkills();
        if (skills) actions.append(skills);
      } else if (this.page?.type === "pull_request") {
        actions.append(this.permissionPrompt(
          "Run Skills",
          "skill:run",
          "Analysis actions are off for this client."
        ));
      }
      if (actions.children.length) panel.append(actions);

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
    renderRunnableSkills() {
      const runnableSkills = this.snapshot?.skills?.filter((skill) => skill.is_runnable) || [];
      if (!runnableSkills.length) return null;
      const skills = createElement(this.document, "details", { className: "ghpr-section" });
      skills.append(createElement(this.document, "summary", { text: "Run Skill" }));
      for (const skill of runnableSkills) {
        skills.append(this.runAction(skill.display_name, {
          kind: "run_skill",
          skill_id: skill.id
        }));
      }
      return skills;
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


    latestCodeReview() {
      return [...(this.snapshot?.runs || [])]
        .sort((left, right) =>
          String(right.completed_at || "").localeCompare(String(left.completed_at || ""))
        )
        .map((run) => run.result?.code_review)
        .find(Boolean) || null;
    }

    jobNameForRow(row) {
      const explicit = row.dataset.jobName ||
        row.querySelector("[data-check-name], [data-job-name]")?.textContent;
      if (explicit?.trim()) return explicit.trim();
      const statusPattern = /\b(failed|failure|success|passed|skipped|cancelled|queued|running)\b/i;
      const candidates = [...row.querySelectorAll("a, [title], span, strong, p")];
      return candidates
        .map((candidate) => candidate.textContent?.trim())
        .find((text) => text && !statusPattern.test(text) && text.length <= 160) || null;
    }

    analysisForCheck(row) {
      const text = (this.jobNameForRow(row) || row.textContent || "").trim().toLocaleLowerCase();
      const analyses = this.snapshot?.analyses || [];
      return analyses.find((analysis) => {
        const name = String(analysis.job_name || "").trim().toLocaleLowerCase();
        return name && (name === text || text.includes(name));
      }) || null;
    }

    findingURL(finding) {
      const page = this.snapshot?.page;
      const number = page?.pr_number;
      if (!page || !number || !finding) return null;
      // A finding whose anchor no longer resolves on the latest revision is
      // only viewable on the diff of the commit it was reviewed against.
      if (!finding.file) return this.reviewedRevisionFilesURLV2(finding);
      const url = new URL(
        `https://github.com/${page.repository}/pull/${number}/changes`
      );
      url.searchParams.set("ghpr_finding", finding.id);
      url.searchParams.set("path", finding.file);
      if (finding.line) {
        url.searchParams.set("line", String(finding.line));
        url.hash = `L${finding.line}`;
      }
      return url.href;
    }

    navigateToFinding(finding) {
      const href = this.findingURL(finding);
      if (href) this.window.location.href = href;
    }

    editorURLV2(finding) {
      const page = this.snapshot?.page;
      const revision = this.snapshot?.current_revision_subject;
      const file = finding?.file;
      const line = finding?.end_line || finding?.line;
      if (!page?.repository || !revision?.head_sha || !file || !line) return null;
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(page.repository)) return null;
      if (!/^[0-9a-f]{40}$/i.test(revision.head_sha)) return null;
      if (file.startsWith("/") || file.split("/").includes("..")) return null;
      return `https://github.dev/${page.repository}/blob/${revision.head_sha}/${file}#L${line}`;
    }

    async dismissFinding(findingID) {
      if (!this.isSurfaceV2()) {
        this.dismissedFindingIDs.add(findingID);
        await this.gm.setValue(
          STORAGE.dismissedFindings,
          [...this.dismissedFindingIDs]
        );
        return true;
      }
      if (!this.hasScope("finding:write")) {
        this.renderTransientError("finding:write permission is required to dismiss this finding.");
        return false;
      }
      try {
        await this.bridge.request(
          "POST",
          `/api/v1/findings/${encodeURIComponent(findingID)}/dismiss`
        );
        if (this.snapshot?.findings) {
          this.snapshot.findings = this.snapshot.findings.filter((finding) => finding.id !== findingID);
        }
        return true;
      } catch (error) {
        this.renderTransientError(error.message);
        return false;
      }
    }

    renderFinding(finding, { inline = false } = {}) {
      const confidence = confidencePercent(finding.confidence);
      const location = finding.line ? `${finding.file}:${finding.line}` : finding.file;
      const element = createElement(this.document, inline ? "div" : "article", {
        className: inline ? "ghpr-inline-panel" : "ghpr-finding",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "data-testid": "ghpr-review-finding",
          "data-finding-id": finding.id
        }
      });
      const head = createElement(this.document, "div", {
        className: "ghpr-finding-head"
      }, [
        createElement(this.document, "span", {
          className: "ghpr-finding-title",
          text: finding.body || finding.category || "Review finding"
        }),
        createElement(this.document, "span", {
          className: `ghpr-badge ghpr-tone-${findingSeverityTone(finding.severity)}`,
          text: `${finding.severity || "info"}${confidence ? ` · ${confidence}` : ""}`
        })
      ]);
      element.append(
        head,
        createElement(this.document, "div", {
          className: "ghpr-finding-meta",
          text: location
        })
      );
      if (finding.quoted_code) {
        element.append(createElement(this.document, "pre", {
          className: "ghpr-mini-diff",
          text: finding.quoted_code
        }));
      }
      if (finding.details?.why) {
        element.append(createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: finding.details.why
        }));
      }
      const tools = createElement(this.document, "div", {
        className: "ghpr-finding-tools"
      });
      if (!inline && this.findingURL(finding)) {
        tools.append(button(this.document, "View in Files changed", () =>
          this.navigateToFinding(finding)
        ));
      }
      if (inline) {
        const raw = createElement(this.document, "pre", {
          className: "ghpr-mini-diff ghpr-raw-diagnostics",
          text: JSON.stringify(finding, null, 2)
        });
        raw.hidden = true;
        tools.append(
          button(this.document, "Dismiss", async () => {
            await this.dismissFinding(finding.id);
            element.remove();
          }),
          createElement(this.document, "button", {
            className: "ghpr-button",
            text: "Open in editor",
            type: "button",
            title: "Local editor integration is not configured.",
            disabled: true
          }),
          button(this.document, "Raw diagnostics", () => {
            raw.hidden = !raw.hidden;
          })
        );
        element.append(raw);
      }
      if (tools.children.length) element.append(tools);
      return element;
    }

    renderReviewSummaryCard(review) {
      const host = semanticTargets(this.document, "pr.mergebox.after")[0];
      if (!host) return;
      const findings = (review.findings || [])
        .filter((finding) => !this.dismissedFindingIDs.has(finding.id));
      const card = createElement(this.document, "section", {
        className: "ghpr-card ghpr-review-summary",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "aria-label": "ghpr Review Summary"
        }
      }, [
        createElement(this.document, "div", { className: "ghpr-card-head" }, [
          createElement(this.document, "span", {
            className: "ghpr-card-title",
            text: "ghpr Review Summary"
          }),
          createElement(this.document, "span", {
            className: "ghpr-badge ghpr-tone-analysis",
            text: "Beta"
          })
        ]),
        createElement(this.document, "div", {
          className: "ghpr-review-meta",
          text: `Reviewed revision: ${review.head_sha || "current"} · ${findings.length} findings · ${new Set(findings.map((finding) => finding.file)).size} files`
        }),
        createElement(this.document, "p", {
          className: "ghpr-card-summary",
          text: review.overview_markdown || "Review findings from ghpr."
        })
      ]);
      for (const finding of findings) card.append(this.renderFinding(finding));
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
      const review = this.latestCodeReview();
      if (review) {
        this.renderReviewSummaryCard(review);
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

    renderInsight(analysis) {
      const insight = createElement(this.document, "div", {
        className: "ghpr-insight",
        attributes: { [MANAGED_ATTRIBUTE]: "" }
      });
      insight.append(
        createElement(this.document, "h4", { text: "Why it failed" }),
        createElement(this.document, "p", { text: analysis.summary || "No failure summary yet." }),
        createElement(this.document, "h4", { text: "Flaky evidence" }),
        createElement(this.document, "p", {
          text: analysis.relatedness_summary || analysis.suggested_action || "No additional evidence."
        }),
        createElement(this.document, "h4", { text: "History" }),
        createElement(this.document, "p", {
          text: `${analysis.history_matches?.length || 0} / ${analysis.history_checked || 0} matching runs`
        }),
        createElement(this.document, "h4", { text: "Suggested action" }),
        createElement(this.document, "p", { text: analysis.suggested_action || "Inspect the full result." })
      );
      return insight;
    }

    renderCheckActions(jobName) {
      const actions = createElement(this.document, "details", {
        className: "ghpr-check-actions",
        attributes: { [MANAGED_ATTRIBUTE]: "" }
      });
      actions.append(createElement(this.document, "summary", { text: "Analyze ▾" }));
      for (const [label, skillID] of [
        ["Explain CI Failure", "ci.failure.explain"],
        ["Classify Flaky", "ci.failure.classify_flaky"]
      ]) {
        actions.append(this.runAction(label, {
          kind: "run_skill",
          skill_id: skillID,
          job_name: jobName
        }, "ghpr-button"));
      }
      return actions;
    }
    renderCheckRows() {
      if (this.page?.type !== "pull_request") return;
      const candidates = semanticTargets(this.document, "checks.run.trailing");
      for (const row of candidates) {
        if (!/\b(failed|failure)\b/i.test(row.textContent || "")) continue;
        if (row.querySelector(":scope > .ghpr-check-tools")) continue;
        const analysis = this.analysisForCheck(row);
        const jobName = analysis?.job_name || this.jobNameForRow(row);
        if (!jobName) continue;
        const activeRuns = (this.snapshot.runs || []).filter((run) =>
          ["queued", "running"].includes(run.status)
        );
        const activeRun = activeRuns.find((run) => {
          const runJob = run.preferred_job_name || run.result?.analysis?.job_name;
          return runJob && runJob.toLocaleLowerCase() === jobName.toLocaleLowerCase();
        }) || (activeRuns.length === 1 ? activeRuns[0] : null);
        const tools = createElement(this.document, "span", {
          className: "ghpr-check-tools",
          attributes: { [MANAGED_ATTRIBUTE]: "" }
        });
        if (activeRun) {
          tools.append(createElement(this.document, "span", {
            className: "ghpr-badge ghpr-tone-analysis",
            text: "Running"
          }));
          if (this.hasScope("detail:open")) {
            tools.append(button(this.document, "View log", () =>
              this.invokeAction({ kind: "open_detail", run_id: activeRun.id })
            ));
          }
          if (this.hasScope("skill:cancel")) {
            tools.append(button(this.document, "Cancel", () =>
              this.invokeAction({ kind: "cancel_run", run_id: activeRun.id })
            ));
          }
        } else {
          if (analysis) {
            tools.append(createElement(this.document, "span", {
              className: `ghpr-badge ghpr-tone-${toneForVerdict(analysis.verdict)}`,
              text: `${labelForVerdict(analysis.verdict)}${confidencePercent(analysis.confidence_score) ? ` · ${confidencePercent(analysis.confidence_score)}` : ""}`
            }));
          }
          if (this.hasScope("skill:run")) {
            tools.append(this.renderCheckActions(jobName));
          }
        }
        if (analysis) {
          const insight = createElement(this.document, "details", {
            className: "ghpr-check-insight",
            attributes: { [MANAGED_ATTRIBUTE]: "" }
          });
          insight.open = true;
          insight.append(
            createElement(this.document, "summary", { text: "ghpr CI Insight" }),
            this.renderInsight(analysis)
          );
          row.append(insight);
        }
        if (tools.children.length) row.append(tools);
      }
    }

    findingsForSnapshot(allowLegacyFallback = true) {
      const review = this.latestCodeReview();
      const reviewFindings = review?.findings || [];
      const persisted = (this.snapshot.findings || []).map((finding) => {
        const original = finding.subject || {};
        const resolved = ["exact", "remapped"].includes(finding.lifecycle)
          ? (finding.resolved_subject || original)
          : {};
        const payload = reviewFindings.find((candidate) => candidate.id === finding.id) || {};
        return {
          id: finding.id,
          title: finding.title,
          body: finding.summary,
          summary: finding.summary,
          details_text: finding.details,
          details: payload.details,
          severity: finding.severity,
          confidence: finding.confidence,
          category: finding.kind,
          fingerprint: finding.fingerprint,
          lifecycle: finding.lifecycle,
          file: resolved.file_path,
          side: resolved.side,
          start_line: resolved.start_line,
          end_line: resolved.end_line,
          line: resolved.end_line,
          original_file: original.file_path,
          original_start_line: original.start_line,
          original_end_line: original.end_line,
          original_side: original.side,
          reviewed_head_sha: original.head_sha,
          reviewed_base_sha: original.base_sha,
          quoted_code: original.quoted_code,
          snippet: payload.snippet,
          subject_key: finding.subject_key
        };
      });
      if (persisted.length) return persisted;
      if (!allowLegacyFallback) return [];
      if (reviewFindings.length) return reviewFindings;
      return (this.snapshot.analyses || []).flatMap((analysis) => analysis.findings || []);
    }

    renderWorkflowRunInsight() {
      const host = semanticTargets(this.document, "checks.job.trailing")[0];
      if (!host || host.querySelector(":scope > .ghpr-workflow-insight")) return;
      const analysis = this.snapshot.analyses?.[0] ||
        this.snapshot.runs?.find((run) => run.result?.analysis)?.result?.analysis;
      if (!analysis) return;
      const card = createElement(this.document, "section", {
        className: "ghpr-card ghpr-workflow-insight",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "aria-label": "ghpr CI Insight"
        }
      }, [
        createElement(this.document, "div", {
          className: "ghpr-card-title",
          text: "ghpr CI Insight"
        }),
        this.renderInsight(analysis)
      ]);
      host.append(card);
    }

    renderFilesFindings() {
      const hosts = semanticTargets(this.document, "files.diff.line-decoration");
      if (!hosts.length) return;
      const findings = this.findingsForSnapshot()
        .filter((finding) => !this.dismissedFindingIDs.has(finding.id));
      if (!findings.length) return;
      const host = hosts[0];
      if (host.querySelector(":scope > .ghpr-files-findings")) return;
      const section = createElement(this.document, "section", {
        className: "ghpr-card ghpr-files-findings",
        attributes: {
          [MANAGED_ATTRIBUTE]: "",
          "aria-label": "ghpr Findings in Files changed"
        }
      }, [
        createElement(this.document, "div", {
          className: "ghpr-card-title",
          text: "ghpr Findings"
        })
      ]);
      for (const finding of findings) {
        section.append(this.renderFinding(finding, { inline: true }));
      }
      host.insertAdjacentElement("beforebegin", section);
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
          const headerFallback = this.headerMenu?.querySelector("[data-ghpr-header-fallback]");
          if (headerFallback) {
            headerFallback.hidden = false;
            headerFallback.append(this.renderContribution(contribution, true));
          }
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
      if (!message) return;
      if (this.isSurfaceV2() && this.drawerHost && global.GhprSurfaceRenderers) {
        const content = global.GhprSurfaceRenderers.renderSurface(
          this.document,
          "detail_drawer",
          { title: "ghpr unavailable", raw: String(message) }
        );
        this.drawerHost.open(content);
        return;
      }
      const root = this.document.getElementById(ROOT_ID);
      if (!root) return;
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
    isFilesChangedSurface,
    filesChangedRevisionRef,
    createGhprApp,
    parseGitHubPage,
    semanticTargets
  };
  global.GhprUserscript = exported;
  if (typeof module !== "undefined" && module.exports) module.exports = exported;

  if (!global.__GHPR_TEST__ && global.document) {
    createGhprApp().start().catch((error) => {
      // A missing local app resolves silently inside refresh(); reaching this
      // handler means the userscript itself failed, so it must say so instead
      // of leaving the page untouched with no explanation.
      global.console?.error?.("[ghpr] userscript failed to start:", error);
    });
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
