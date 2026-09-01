// Minimal static file server used as the Playwright `webServer` for browser/e2e tests.
// Serves GitHub-shaped HTML fixtures (added under browser/e2e/fixtures or browser/tests/fixtures)
// so Chromium-driven specs can exercise the rendered surfaces against real markup.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = fileURLToPath(new URL('.', import.meta.url));
const roots = [join(here, 'fixtures'), join(here, '..', 'tests', 'fixtures')];

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
};

async function resolveFile(requestPath) {
  const relative = normalize(requestPath).replace(/^([.][.][/\\])+/, '');
  for (const root of roots) {
    const candidate = join(root, relative);
    if (!candidate.startsWith(root)) continue;
    try {
      const info = await stat(candidate);
      if (info.isFile()) return candidate;
    } catch {
      // try next root
    }
  }
  return null;
}

const port = Number(process.env.GHPR_E2E_PORT ?? 4173);

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://localhost');
  let pathname = url.pathname === '/' ? '/index.html' : url.pathname;
  const file = await resolveFile(pathname);
  if (!file) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
    return;
  }
  const body = await readFile(file);
  res.writeHead(200, { 'content-type': CONTENT_TYPES[extname(file)] ?? 'application/octet-stream' });
  res.end(body);
});

server.listen(port, () => {
  // eslint-disable-next-line no-console
  console.log(`ghpr e2e fixture server listening on http://127.0.0.1:${port}`);
});
