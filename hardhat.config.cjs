require('./tools/vendor-loader.cjs');
const { subtask } = require('hardhat/config');
const {
  TASK_COMPILE_GET_REMAPPINGS,
  TASK_COMPILE_SOLIDITY_GET_COMPILER_INPUT,
  TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD
} = require('hardhat/builtin-tasks/task-names');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');

const remappings = fs.readFileSync(path.join(__dirname, 'remappings.txt'), 'utf8').trim().split('\n');
const mapping = Object.fromEntries(remappings.map(line => line.trim().split('=')));
subtask(TASK_COMPILE_GET_REMAPPINGS).setAction(async () => mapping);

// Hardhat resolves remapped files but preserves import aliases as source names. Canonicalize them
// for solc so v4-core/ and @uniswap/v4-core/ describe the same Solidity types, as in Foundry.
subtask(TASK_COMPILE_SOLIDITY_GET_COMPILER_INPUT).setAction(async (args, hre, runSuper) => {
  const input = await runSuper(args);
  const sources = {};
  for (const [name, source] of Object.entries(input.sources)) {
    const prefix = Object.keys(mapping).find(prefix => name.startsWith(prefix));
    const canonical = prefix ? mapping[prefix] + name.slice(prefix.length) : name;
    if (sources[canonical] && sources[canonical].content !== source.content) throw new Error('Conflicting source alias');
    sources[canonical] = source;
  }
  input.sources = sources;
  input.settings.remappings = remappings;
  return input;
});

// Use the compiler installed for Foundry; no download, compiler binary, or absolute machine path
// is part of the repository. Reject any executable that does not report the exact pinned version.
subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD).setAction(async ({ solcVersion }) => {
  if (solcVersion !== '0.8.26') throw new Error('Only Solidity 0.8.26 is supported');
  const candidates = ['solc', path.join(os.homedir(), '.svm', solcVersion, `solc-${solcVersion}`)];
  for (const compilerPath of candidates) {
    try {
      const version = execFileSync(compilerPath, ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
      if (!version.includes('0.8.26+commit.8a97fa7a')) continue;
      return { compilerPath, isSolcJs: false, version: solcVersion, longVersion: '0.8.26+commit.8a97fa7a' };
    } catch {}
  }
  throw new Error('Install Solidity 0.8.26 with Foundry/SVM, or put that exact solc on PATH. No network download is attempted.');
});

module.exports = {
  solidity: {
    version: '0.8.26',
    settings: { evmVersion: 'cancun', optimizer: { enabled: true, runs: 200 }, metadata: { bytecodeHash: 'none' } }
  },
  paths: { sources: './src', tests: './test', artifacts: './artifacts', cache: './cache-hardhat/solidity' }
};
