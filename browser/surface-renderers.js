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
    checksSummary: "github.pr.checks.summary",
    checksJobInsight: "github.pr.checks.job.insight",
    actionsJobAfterFailureSummary: "github.actions.job.after-failure-summary",
    filesFileHeader: "github.pr.files.file.header",
    filesDiffLineAfter: "github.pr.files.diff.line.after",
    pageFindingDrawer: "github.page.finding-drawer",
    reviewLaunchDialog: "github.pr.review-launch-dialog"
  });

  const VIEW_TYPES = Object.freeze([
    "job_verdict",
    "ci_insight",
    "ci_summary",
    "review_summary",
    "review_launch_dialog",
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
    .ghpr-job-reason {
      color: var(--fgColor-muted, #656d76);
      flex: 1 1 180px;
      max-width: 360px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .ghpr-ci-summary {
      background: var(--bgColor-attention-muted, #fff8c5);
      border: 1px solid var(--borderColor-attention-muted, #d4a72c66);
      color: #1f2328;
      border-radius: 6px;
      margin: 8px 0;
      padding: 10px 12px;
    }
    .ghpr-ci-summary-title {
      font-weight: 600;
      margin: 0 0 4px;
    }
    .ghpr-ci-summary-list {
      margin: 0;
      padding-left: 18px;
    }
    @media (prefers-color-scheme: dark) {
      .ghpr-ci-summary {
        background: #2d2a12;
        border-color: #9e6a03;
        color: #f0f6fc;
      }
    }
    :root[data-color-mode="dark"] .ghpr-ci-summary {
      background: #2d2a12;
      border-color: #9e6a03;
      color: #f0f6fc;
    }
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
      overflow: visible;
    }
    .ghpr-review-summary-checks {
      align-items: center;
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      gap: 8px;
      justify-content: space-between;
      padding: 8px 12px;
      border-radius: 6px 6px 0 0;
    }
    .ghpr-review-summary-checks-copy { color: var(--fgColor-muted, #656d76); }
    .ghpr-review-summary-checks-copy[data-hint] {
      cursor: help;
      outline-offset: 2px;
      position: relative;
    }
    .ghpr-review-summary-checks-copy[data-hint]::after {
      background: var(--bgColor-emphasis, #25292e);
      border-radius: 6px;
      color: var(--fgColor-onEmphasis, #fff);
      content: attr(data-hint);
      display: none;
      font-size: 12px;
      left: 0;
      max-width: min(420px, 80vw);
      padding: 8px 10px;
      position: absolute;
      top: calc(100% + 6px);
      white-space: pre-line;
      width: max-content;
      z-index: 1000;
    }
    .ghpr-review-summary-checks-copy[data-hint]:hover::after,
    .ghpr-review-summary-checks-copy[data-hint]:focus-visible::after {
      display: block;
    }
    .ghpr-review-summary-checks-actions {
      align-items: center;
      display: flex;
      gap: 4px;
    }
    .ghpr-review-summary-check-action {
      background: transparent;
      border-color: transparent;
      border-radius: 4px;
      color: var(--fgColor-accent, #0969da);
      font-size: 11px;
      font-weight: 600;
      min-height: 24px;
      padding: 2px 6px;
    }
    .ghpr-review-summary-check-action:hover {
      background: var(--bgColor-accent-muted, #ddf4ff);
      border-color: transparent;
    }
    .ghpr-review-summary-rerun::before {
      content: "↻";
      font-size: 15px;
      font-weight: 400;
      line-height: 1;
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
    .ghpr-surface-modal-backdrop {
      align-items: center;
      background: rgba(31, 35, 40, .45);
      display: flex;
      inset: 0;
      justify-content: center;
      padding: 24px;
      position: fixed;
      z-index: 10000;
    }
    .ghpr-surface-modal {
      background: var(--bgColor-default, #fff);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 12px;
      box-shadow: var(--shadow-floating-large, 0 16px 48px rgba(31, 35, 40, .24));
      max-height: calc(100vh - 48px);
      max-width: 560px;
      overflow: auto;
      position: relative;
      width: 100%;
    }
    .ghpr-surface-modal-close {
      align-items: center;
      appearance: none;
      background: transparent;
      border: 0;
      border-radius: 6px;
      color: var(--fgColor-muted, #656d76);
      cursor: pointer;
      display: inline-flex;
      font-size: 20px;
      height: 32px;
      justify-content: center;
      position: absolute;
      right: 12px;
      top: 12px;
      width: 32px;
      z-index: 1;
    }
    .ghpr-surface-modal-close:hover {
      background: var(--button-default-bgColor-hover, var(--bgColor-neutral-muted, #eaeef2));
      color: var(--fgColor-default, #1f2328);
    }
    .ghpr-review-launch-head { padding: 20px 52px 14px 20px; }
    .ghpr-review-launch-title {
      font-size: 18px;
      line-height: 1.35;
      margin: 0;
    }
    .ghpr-review-launch-subtitle {
      color: var(--fgColor-muted, #656d76);
      margin: 4px 0 0;
    }
    .ghpr-review-revision-rail {
      align-items: center;
      background: var(--bgColor-muted, #f6f8fa);
      border-bottom: 1px solid var(--borderColor-muted, #d8dee4);
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
      display: flex;
      font: 11px ui-monospace, "SFMono-Regular", Consolas, monospace;
      gap: 8px;
      padding: 9px 20px;
    }
    .ghpr-review-revision-label {
      color: var(--fgColor-muted, #656d76);
      font: 600 10px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      letter-spacing: .04em;
      margin-right: auto;
      text-transform: uppercase;
    }
    .ghpr-review-revision-arrow { color: var(--fgColor-accent, #0969da); }
    .ghpr-review-launch-section { padding: 18px 20px; }
    .ghpr-review-launch-section + .ghpr-review-launch-section {
      border-top: 1px solid var(--borderColor-muted, #d8dee4);
    }
    .ghpr-review-launch-section h3 {
      font-size: 13px;
      margin: 0 0 3px;
    }
    .ghpr-review-launch-section-copy {
      color: var(--fgColor-muted, #656d76);
      margin: 0 0 14px;
    }
    .ghpr-review-launch-fields {
      display: grid;
      gap: 12px;
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .ghpr-review-launch-field {
      display: flex;
      flex-direction: column;
      gap: 5px;
      min-width: 0;
    }
    .ghpr-review-launch-field > span {
      font-size: 11px;
      font-weight: 600;
    }
    .ghpr-review-launch-field select,
    .ghpr-review-launch-field input {
      appearance: none;
      background: var(--bgColor-default, #fff);
      border: 1px solid var(--borderColor-default, #d1d9e0);
      border-radius: 6px;
      color: var(--fgColor-default, #1f2328);
      font: inherit;
      height: 34px;
      min-width: 0;
      padding: 6px 10px;
      width: 100%;
    }
    .ghpr-review-launch-field select {
      background-image: linear-gradient(45deg, transparent 50%, currentColor 50%), linear-gradient(135deg, currentColor 50%, transparent 50%);
      background-position: calc(100% - 14px) 14px, calc(100% - 10px) 14px;
      background-repeat: no-repeat;
      background-size: 4px 4px, 4px 4px;
      padding-right: 28px;
    }
    .ghpr-review-launch-field select:focus,
    .ghpr-review-launch-field input:focus {
      border-color: var(--focus-outlineColor, #0969da);
      box-shadow: 0 0 0 3px var(--focus-outlineColor, #0969da33);
      outline: none;
    }
    .ghpr-review-launch-actions {
      align-items: center;
      display: flex;
      gap: 10px;
      justify-content: flex-end;
      margin-top: 16px;
    }
    .ghpr-review-import-tool {
      background: var(--bgColor-muted, #f6f8fa);
      border: 1px solid var(--borderColor-muted, #d8dee4);
      border-radius: 6px;
      color: var(--fgColor-default, #1f2328);
      display: inline-block;
      font: 11px ui-monospace, "SFMono-Regular", Consolas, monospace;
      margin: 0 0 12px;
      padding: 5px 8px;
    }
    @media (max-width: 560px) {
      .ghpr-surface-modal-backdrop { align-items: flex-end; padding: 0; }
      .ghpr-surface-modal { border-radius: 12px 12px 0 0; max-height: 92vh; max-width: none; }
      .ghpr-review-launch-fields { grid-template-columns: 1fr; }
    }
    @media (prefers-reduced-motion: reduce) {
      .ghpr-surface-modal { scroll-behavior: auto; }
    }
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
      className: ["ghpr-action-button", action.className].filter(Boolean).join(" "),
      text: action.label,
      attrs: {
        type: "button",
        "data-primary": action.primary ? "true" : undefined,
        "data-action-id": action.id,
        title: action.title,
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
  // model: { status, confidencePercent, reason, actions: [{id,label,primary,onSelect}] }
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
    if (model.reason) {
      children.push(h(document, "span", {
        className: "ghpr-job-reason",
        text: model.reason,
        attrs: { title: model.reason }
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

  // --- ci_summary ----------------------------------------------------------
  // model: { title, reasons: [{label, reason}] }
  function renderCISummary(document, model = {}) {
    const reasons = (model.reasons || []).filter((item) => item?.reason);
    return h(document, "section", { className: "ghpr-surface ghpr-ci-summary" }, [
      h(document, "p", {
        className: "ghpr-ci-summary-title",
        text: model.title || "ghpr CI failure summary"
      }),
      h(document, "ul", { className: "ghpr-ci-summary-list" }, reasons.map((item) =>
        h(document, "li", {
          text: item.label ? `${item.label}: ${item.reason}` : item.reason
        })
      ))
    ]);
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

    const checksActions = model.checksActions;
    const checkButtons = Array.isArray(checksActions?.actions)
      ? checksActions.actions
          .filter((action) => typeof action?.onSelect === "function")
          .map((action) => renderActionButton(document, {
            ...action,
            className: [
              "ghpr-review-summary-check-action",
              action.className
            ].filter(Boolean).join(" ")
          }))
      : [];
    const checksRow = checksActions && checkButtons.length
      ? h(document, "div", { className: "ghpr-review-summary-checks" }, [
          h(document, "span", {
            className: "ghpr-review-summary-checks-copy",
            text: checksActions.summary || "",
            attrs: {
              tabindex: checksActions.hint ? "0" : undefined,
              "data-hint": checksActions.hint || undefined,
              "aria-label": checksActions.hint
                ? `${checksActions.summary || ""}. ${checksActions.hint.replace(/\n/g, " ")}`
                : undefined
            }
          }),
          h(document, "div", {
            className: "ghpr-review-summary-checks-actions"
          }, checkButtons)
        ])
      : null;

    return h(document, "div", { className: "ghpr-surface ghpr-review-summary" }, [
      checksRow,
      identity,
      h(document, "div", { className: "ghpr-review-summary-toolbar" }, toolbar),
      meta,
      findingsList
    ]);
  }

  function renderReviewLaunchDialog(document, model = {}) {
    const runtimes = Array.isArray(model.runtimes) ? model.runtimes : [];
    const selectedRuntimeID = model.selectedRuntime ||
      runtimes.find((runtime) => runtime.selected)?.id ||
      runtimes[0]?.id ||
      "";
    const runtimeSelect = h(document, "select", {
      attrs: { id: "ghpr-review-runtime", "aria-label": "Review runtime" }
    });
    for (const runtime of runtimes) {
      runtimeSelect.append(h(document, "option", {
        text: runtime.label || runtime.id,
        attrs: { value: runtime.id }
      }));
    }
    runtimeSelect.value = selectedRuntimeID;

    const modelField = h(document, "label", { className: "ghpr-review-launch-field" });
    const effortField = h(document, "label", { className: "ghpr-review-launch-field" });
    let modelControl = null;
    let effortControl = null;

    const runtimeConfig = () =>
      runtimes.find((runtime) => runtime.id === runtimeSelect.value) || runtimes[0] || {};
    const effortOptions = (runtime, modelID) => {
      const modelOption = (runtime.models || []).find((option) => option.slug === modelID);
      const options = modelOption?.reasoningEfforts?.length
        ? modelOption.reasoningEfforts
        : (runtime.reasoningEfforts || []);
      const preferred = runtime.selectedReasoningEffort || "";
      return {
        options,
        selected: options.some((option) => option.effort === preferred)
          ? preferred
          : (modelOption?.defaultEffort || "")
      };
    };
    const renderEffortControl = (runtime, modelID) => {
      const { options, selected } = effortOptions(runtime, modelID);
      effortField.replaceChildren();
      effortControl = null;
      if (!options.length) {
        effortField.hidden = true;
        return;
      }
      effortField.hidden = false;
      effortControl = h(document, "select", {
        attrs: { id: "ghpr-review-reasoning", "aria-label": "Reasoning effort" }
      }, [
        h(document, "option", { text: "Runtime default", attrs: { value: "" } }),
        ...options.map((option) => h(document, "option", {
          text: option.detail ? `${option.effort} — ${option.detail}` : option.effort,
          attrs: { value: option.effort }
        }))
      ]);
      effortControl.value = selected;
      effortField.append(
        h(document, "span", { text: "Reasoning" }),
        effortControl
      );
    };
    const renderModelControl = () => {
      const runtime = runtimeConfig();
      const models = Array.isArray(runtime.models) ? runtime.models : [];
      modelField.replaceChildren();
      if (models.length) {
        modelControl = h(document, "select", {
          attrs: { id: "ghpr-review-model", "aria-label": "Review model" }
        }, [
          h(document, "option", { text: "Runtime default", attrs: { value: "" } }),
          ...models.map((option) => h(document, "option", {
            text: option.displayName || option.slug,
            attrs: { value: option.slug }
          }))
        ]);
      } else {
        modelControl = h(document, "input", {
          attrs: {
            id: "ghpr-review-model",
            type: "text",
            maxlength: "80",
            placeholder: "Runtime default or model name",
            "aria-label": "Review model"
          }
        });
      }
      modelControl.value = runtime.selectedModel || "";
      modelControl.addEventListener("change", () =>
        renderEffortControl(runtimeConfig(), modelControl.value)
      );
      modelField.append(
        h(document, "span", { text: "Model" }),
        modelControl
      );
      renderEffortControl(runtime, modelControl.value);
    };
    runtimeSelect.addEventListener("change", renderModelControl);
    renderModelControl();
    const startLabel = model.startLabel || "Start review";
    const startingLabel = model.startingLabel || "Starting…";

    const startButton = h(document, "button", {
      className: "ghpr-action-button",
      text: startLabel,
      attrs: {
        type: "button",
        "data-action-id": model.startActionID || "start-review",
        "data-primary": "true"
      }
    });
    startButton.addEventListener("click", async () => {
      if (typeof model.onStart !== "function" || startButton.disabled) return;
      startButton.disabled = true;
      startButton.textContent = startingLabel;
      try {
        const started = await model.onStart({
          agent: runtimeSelect.value,
          model: modelControl?.value || null,
          reasoningEffort: effortControl?.value || null
        });
        if (!started) {
          startButton.disabled = false;
          startButton.textContent = startLabel;
        }
      } catch {
        startButton.disabled = false;
        startButton.textContent = startLabel;
      }
    });

    const copyPrompt = renderCopyButton(document, {
      id: "copy-import-prompt",
      label: "Copy import prompt",
      className: "ghpr-action-button",
      ariaLabel: "Copy instructions for importing an external review",
      onCopy: model.onCopyImportPrompt
    });

    return h(document, "div", { className: "ghpr-surface ghpr-review-launch" }, [
      h(document, "div", { className: "ghpr-review-launch-head" }, [
        h(document, "h2", {
          className: "ghpr-review-launch-title",
          text: model.title || "Review this revision"
        }),
        h(document, "p", {
          className: "ghpr-review-launch-subtitle",
          text: model.subtitle || "Choose how this exact pull request revision should be reviewed."
        })
      ]),
      h(document, "div", {
        className: "ghpr-review-revision-rail",
        attrs: {
          title: `${model.baseSHA || ""}…${model.headSHA || ""}`,
          "aria-label": `Review revision ${model.baseSHA || ""} to ${model.headSHA || ""}`
        }
      }, [
        h(document, "span", { className: "ghpr-review-revision-label", text: `${model.repository || ""}#${model.number || ""}` }),
        h(document, "span", { text: String(model.baseSHA || "").slice(0, 7) }),
        h(document, "span", { className: "ghpr-review-revision-arrow", text: "→", attrs: { "aria-hidden": "true" } }),
        h(document, "strong", { text: String(model.headSHA || "").slice(0, 7) })
      ]),
      h(document, "section", { className: "ghpr-review-launch-section" }, [
        h(document, "h3", { text: model.sectionTitle || "Run review with ghpr" }),
        h(document, "p", {
          className: "ghpr-review-launch-section-copy",
          text: model.sectionCopy || "ghpr prepares the exact diff and runs the selected coding agent locally."
        }),
        h(document, "div", { className: "ghpr-review-launch-fields" }, [
          h(document, "label", { className: "ghpr-review-launch-field" }, [
            h(document, "span", { text: "Runtime" }),
            runtimeSelect
          ]),
          modelField,
          effortField
        ]),
        h(document, "div", { className: "ghpr-review-launch-actions" }, [startButton])
      ]),
      model.showImport === false
        ? null
        : h(document, "section", { className: "ghpr-review-launch-section" }, [
            h(document, "h3", { text: "Import an existing review" }),
            h(document, "p", {
              className: "ghpr-review-launch-section-copy",
              text: "Review in your usual CLI session, then ask the agent to save its structured findings through the configured ghpr MCP server."
            }),
            h(document, "code", { className: "ghpr-review-import-tool", text: "ghpr.import_review" }),
            h(document, "div", { className: "ghpr-review-launch-actions" }, [copyPrompt])
          ])
    ]);
  }
  function renderFailedChecksRerunDialog(document, model = {}) {
    return h(document, "div", { className: "ghpr-surface ghpr-review-launch" }, [
      h(document, "div", { className: "ghpr-review-launch-head" }, [
        h(document, "h2", {
          className: "ghpr-review-launch-title",
          text: "Re-run failed jobs?"
        }),
        h(document, "p", {
          className: "ghpr-review-launch-subtitle",
          text: model.canExplain === false
            ? "Re-run the failed GitHub jobs now?"
            : "Would you like ghpr to explain the failed checks before re-running them?"
        })
      ]),
      h(document, "section", { className: "ghpr-review-launch-section" }, [
        h(document, "p", {
          className: "ghpr-review-launch-section-copy",
          text: model.canExplain === false
            ? "This immediately retries the failed GitHub jobs."
            : "Explain CI Failure lets you choose the coding agent runtime and model. Re-run anyway immediately retries the failed GitHub jobs."
        }),
        h(document, "div", { className: "ghpr-review-launch-actions" }, [
          model.canExplain === false
            ? null
            : renderActionButton(document, {
                id: "explain-before-rerun",
                label: "Explain CI Failure",
                onSelect: model.onExplain
              }),
          renderActionButton(document, {
            id: "rerun-anyway",
            label: "Re-run anyway",
            primary: true,
            onSelect: model.onRerun
          })
        ])
      ])
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
    ci_summary: renderCISummary,
    ci_insight: renderCiInsight,
    review_summary: renderReviewSummary,
    review_launch_dialog: renderReviewLaunchDialog,
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

  class ModalHost {
    constructor({ document }) {
      this.document = document;
      this._backdrop = null;
      this._panel = null;
      this._trigger = null;
      this._onClose = null;
      this._keydownHandler = (event) => this._onKeydown(event);
    }

    get isOpen() {
      return !!(this._backdrop && this._backdrop.isConnected);
    }

    open(contentElement, { onClose = null, triggerEl = null, ariaLabel = "Dialog" } = {}) {
      this.close();
      const document = this.document;
      this._trigger = triggerEl || document.activeElement || null;
      this._onClose = onClose;
      const backdrop = h(document, "div", {
        className: "ghpr-surface-modal-backdrop",
        attrs: { "data-ghpr-surface": SURFACE_IDS.reviewLaunchDialog },
        onClick: (event) => {
          if (event.target === backdrop) this.close();
        }
      });
      const closeButton = h(document, "button", {
        className: "ghpr-surface-modal-close",
        text: "\u00d7",
        attrs: { type: "button", "aria-label": "Close" },
        onClick: () => this.close()
      });
      const panel = h(document, "div", {
        className: "ghpr-surface-modal",
        attrs: { role: "dialog", "aria-modal": "true", "aria-label": ariaLabel, tabindex: "-1" }
      }, [closeButton, contentElement]);
      backdrop.appendChild(panel);
      document.body.appendChild(backdrop);
      document.addEventListener("keydown", this._keydownHandler, true);
      this._backdrop = backdrop;
      this._panel = panel;
      const firstControl = panel.querySelector("select, input, button");
      (firstControl || panel).focus?.();
      return panel;
    }

    close() {
      if (!this._backdrop) return;
      const document = this.document;
      document.removeEventListener("keydown", this._keydownHandler, true);
      this._backdrop.remove();
      const trigger = this._trigger;
      const onClose = this._onClose;
      this._backdrop = null;
      this._panel = null;
      this._trigger = null;
      this._onClose = null;
      trigger?.focus?.();
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
    renderReviewLaunchDialog,
    renderFailedChecksRerunDialog,
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
    ModalHost,
    SurfaceRegistry
  };

  global.GhprSurfaceRenderers = exported;
  if (typeof module !== "undefined" && module.exports) module.exports = exported;
})(typeof globalThis !== "undefined" ? globalThis : this);
