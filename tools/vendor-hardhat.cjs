// Maintenance tool, not needed at build time. Downloads registry packages without npm install.
// It never creates node_modules, runs install scripts, or downloads a compiler.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const vendor = path.join(root, 'vendor', 'npm');
const metadata = new Map();
const entries = new Map();
const manifest = { hardhat: 'hardhat-2.26.3', packages: {} };
// This project uses Hardhat for compilation and Foundry for execution/tests. EDR is
// the lazily loaded Hardhat Network simulator, not a compiler dependency.
const omittedHardhatDependencies = {
  solc: 'uses installed solc 0.8.26 via hardhat.config.cjs',
  '@nomicfoundation/edr': 'Hardhat Network simulator; not needed for compile; tests use Foundry'
};

async function json(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${response.status}: ${url}`);
  return response.json();
}

async function extract(meta, directory) {
  const response = await fetch(meta.dist.tarball);
  if (!response.ok) throw new Error(`Download failed: ${meta.dist.tarball}`);
  const data = Buffer.from(await response.arrayBuffer());
  const [algorithm, digest] = meta.dist.integrity.split('-');
  if (crypto.createHash(algorithm).update(data).digest('base64') !== digest) throw new Error('Integrity mismatch');
  const result = spawnSync('python3', [path.join(__dirname, 'extract-package.py'), directory], { input: data });
  if (result.status !== 0) throw new Error(result.stderr.toString());
}

function platformPackage(name) {
  return !/(?:darwin|win32|linux|freebsd|android)/.test(name) || /linux-x64-gnu$/.test(name);
}

async function main() {
  // A pinned, pure-JS semver resolver also lives in the delivered dependency tree.
  const semverMeta = await json('https://registry.npmjs.org/semver/7.7.3');
  await extract(semverMeta, path.join(vendor, 'semver-7.7.3'));
  const semver = require('../vendor/npm/semver-7.7.3');
  async function visit(name, range) {
    if (Object.hasOwn(omittedHardhatDependencies, name) || !platformPackage(name)) return null;
    if (!metadata.has(name)) metadata.set(name, json(`https://registry.npmjs.org/${name}`));
    const all = await metadata.get(name);
    const version = semver.maxSatisfying(Object.keys(all.versions), range);
    if (!version) throw new Error(`Cannot resolve ${name}@${range}`);
    const meta = all.versions[version];
    const id = `${name.replaceAll('/', '+')}-${version}`;
    if (entries.has(id)) return id;
    entries.set(id, true);
    const record = {
      name, version, tarball: meta.dist.tarball, integrity: meta.dist.integrity,
      dependencies: {}, omitted: name === 'hardhat' ? { ...omittedHardhatDependencies } : {}
    };
    manifest.packages[id] = record;
    await extract(meta, path.join(vendor, id));
    for (const [dep, spec] of Object.entries({ ...meta.dependencies, ...meta.optionalDependencies })) {
      const dependency = await visit(dep, spec);
      if (dependency) record.dependencies[dep] = dependency;
    }
    process.stdout.write(`${name}@${version}\n`);
    return id;
  }
  await visit('hardhat', '2.26.3');
  await visit('semver', '7.7.3');
  fs.writeFileSync(path.join(vendor, 'lock.json'), JSON.stringify(manifest, null, 2) + '\n');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
