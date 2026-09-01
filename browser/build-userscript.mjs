#!/usr/bin/env node
// browser/build-userscript.mjs
//
// Assembles the checked-in standalone browser/ghpr.user.js from
// browser/ghpr.user.template.js (the maintained source) by inserting the
// pure browser/surface-renderers.js registry immediately after the
// Tampermonkey metadata block.
//
// Usage:
//   node build-userscript.mjs           # write browser/ghpr.user.js
//   node build-userscript.mjs --check   # verify it is already in sync; exits
//                                          non-zero on drift, never rewrites

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const TEMPLATE_PATH = join(HERE, "ghpr.user.template.js");
const RENDERERS_PATH = join(HERE, "surface-renderers.js");
const OUTPUT_PATH = join(HERE, "ghpr.user.js");

const METADATA_END_MARKER = "// ==/UserScript==";
const GENERATED_BEGIN = "// >>> BEGIN GENERATED: browser/surface-renderers.js (via `npm run build:userscript` in browser/) — do not edit inline, edit the source file instead";
const GENERATED_END = "// <<< END GENERATED: browser/surface-renderers.js";

function readSource(path) {
  return readFileSync(path, "utf8");
}

export function buildUserscript() {
  const template = readSource(TEMPLATE_PATH);
  const renderers = readSource(RENDERERS_PATH).replace(/\n+$/, "");

  const markerIndex = template.indexOf(METADATA_END_MARKER);
  if (markerIndex === -1) {
    throw new Error(`ghpr.user.template.js is missing the "${METADATA_END_MARKER}" metadata terminator`);
  }
  const metadataEnd = markerIndex + METADATA_END_MARKER.length;
  const header = template.slice(0, metadataEnd);
  const body = template.slice(metadataEnd);

  const insertedBlock = [
    "",
    GENERATED_BEGIN,
    renderers,
    GENERATED_END
  ].join("\n");

  return `${header}\n${insertedBlock}${body}`;
}

function main() {
  const check = process.argv.includes("--check");
  const generated = buildUserscript();

  if (check) {
    let current = "";
    try {
      current = readSource(OUTPUT_PATH);
    } catch {
      current = "";
    }
    if (current !== generated) {
      process.stderr.write(
        "browser/ghpr.user.js is out of date with browser/ghpr.user.template.js and/or " +
        "browser/surface-renderers.js. Run `npm run build:userscript` in browser/ to regenerate it.\n"
      );
      process.exitCode = 1;
      return;
    }
    process.stdout.write("browser/ghpr.user.js is in sync.\n");
    return;
  }

  writeFileSync(OUTPUT_PATH, generated, "utf8");
  process.stdout.write(`Wrote ${OUTPUT_PATH}\n`);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) main();
