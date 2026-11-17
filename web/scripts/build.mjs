// Assembles the static site in dist/: app sources + the pinned wllama engine.
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, relative } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const dist = join(root, 'dist');
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
cpSync(join(root, 'src'), dist, { recursive: true });

const wllama = join(root, 'node_modules/@wllama/wllama/esm');
const compat = join(root, 'node_modules/@wllama/wllama-compat/wasm');
mkdirSync(join(dist, 'vendor/wllama'), { recursive: true });
mkdirSync(join(dist, 'vendor/wllama-compat'), { recursive: true });
cpSync(join(wllama, 'index.js'), join(dist, 'vendor/wllama/index.js'));
cpSync(join(wllama, 'wasm/wllama.wasm'), join(dist, 'vendor/wllama/wllama.wasm'));
cpSync(join(compat, 'wllama.js'), join(dist, 'vendor/wllama-compat/wllama.js'));
cpSync(join(compat, 'wllama.wasm'), join(dist, 'vendor/wllama-compat/wllama.wasm'));
cpSync(join(root, 'node_modules/@wllama/wllama/LICENCE'), join(dist, 'vendor/wllama/LICENCE'));

const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path);
    else if (name !== 'sw.js') files.push(relative(dist, path));
  }
};
walk(dist);
files.sort();
const hash = createHash('sha256');
for (const file of files) hash.update(file).update(readFileSync(join(dist, file)));
const buildId = hash.digest('hex').slice(0, 12);
const shell = ['./', ...files.map((f) => './' + f.split('\\').join('/'))];
const sw = readFileSync(join(dist, 'sw.js'), 'utf8')
  .replace('__BUILD_ID__', buildId)
  .replace('__SHELL_FILES__', JSON.stringify(shell));
writeFileSync(join(dist, 'sw.js'), sw);
const app = join(dist, 'app.js');
writeFileSync(app, readFileSync(app, 'utf8').replace('__BUILD_ID__', buildId));
writeFileSync(join(dist, '.nojekyll'), '');
console.log(`dist ready: ${files.length + 1} files, build ${buildId}`);
