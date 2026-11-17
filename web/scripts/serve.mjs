// Minimal static server for local testing of dist/ (no cross-origin isolation,
// matching GitHub Pages).
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const dist = new URL('../dist/', import.meta.url).pathname;
const types = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.wasm': 'application/wasm', '.png': 'image/png', '.webmanifest': 'application/manifest+json',
  '.gguf': 'application/octet-stream',
};
const port = Number(process.env.PORT || 8080);
createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^(\.\.[/\\])+/, '');
  const file = join(dist, path.endsWith('/') ? path + 'index.html' : path);
  if (!file.startsWith(dist)) { res.writeHead(403).end(); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream', 'Access-Control-Allow-Origin': '*' }).end(body);
  } catch { res.writeHead(404).end('not found'); }
}).listen(port, () => console.log(`http://localhost:${port}/`));
