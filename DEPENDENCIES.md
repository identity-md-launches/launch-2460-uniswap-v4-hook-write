# Dependency provenance

Dependencies are vendored as ordinary files, never submodules. Solidity dependencies keep their
upstream source and licenses. The application's MIT license does not relicense upstream files.

| Dependency | Pin | Source |
| --- | --- | --- |
| Uniswap v4-core | 1.0.2 | npm `@uniswap/v4-core`; `lib/v4-core` |
| Uniswap v4-periphery | 1.0.3 | npm `@uniswap/v4-periphery`; `lib/v4-periphery` |
| OpenZeppelin Contracts | 5.0.2 | npm `@openzeppelin/contracts`; `lib/openzeppelin-contracts` |
| forge-std | v1.9.6 | `https://github.com/foundry-rs/forge-std`, release archive; `lib/forge-std` |
| Solmate | c93f7716c9909175d45f6ef80a34a650e2d24e56 | `https://github.com/transmissions11/solmate`; `lib/solmate` |
| Hardhat | 2.26.3 | npm `hardhat`; `vendor/npm/hardhat-2.26.3` |

Top-level npm archive integrity values for the Solidity packages:

```text
@uniswap/v4-core@1.0.2
sha512-X15Tm2wWd+USAzEExMbo+g9naA6QN6mPgWm0MzDwRNlOfaNlepfUpSyt9RSrUfEODspwbyWbcLg6t5nwc/e7lg==
@uniswap/v4-periphery@1.0.3
sha512-JxLL0Djv9XcMvI2PatEnWrCrxuEaYNVhHxstndBOP+aJfh1XLg5ec8SDZ0xyoVfg2ElJTvuKpBgnu90bNValsg==
@openzeppelin/contracts@5.0.2
sha512-ytPc6eLGcHHnapAZ9S+5qsdomhjo6QBHTDRRBFfTxXIpsicMhVPouPgmUPebZZZGX7vt9USA+Z+0M0dSVtSUEA==
```

`vendor/npm/lock.json` pins every JavaScript package by exact version, npm archive URL, integrity
hash, and dependency mapping. `tools/vendor-loader.cjs` resolves those mappings without modifying
Node's installed packages or creating `node_modules`. Package source files are unmodified; tests,
TypeScript source/type declarations, source maps, and unnecessary platform-specific packages were
omitted during extraction. This tree includes the Linux x64 glibc Solidity parser native addon,
which compilation needs, and contains no Solidity compiler binaries.

The Hardhat Network EDR simulator and its native addon are intentionally omitted to keep the
source bundle below the 8 MiB upload limit. Hardhat loads EDR only when its local network provider
is used; `npx hardhat compile` does not need it. Hardhat's compilation tasks and package sources
are unchanged. This is a compilation distribution: use `forge test` for EVM execution. Hardhat
Network commands such as `hardhat node` are not supported by this vendored tree. The lock file
records the omission, and the vendoring script preserves it on refresh.

Hardhat's npm `solc` dependency is intentionally omitted: the compile task resolves the installed
native Solidity 0.8.26 instead. There are no install scripts or compiler downloads in the build.
`tools/vendor-hardhat.cjs` and `tools/extract-package.py` document the maintenance-time fetch and
integrity-verification process. They require network access only when deliberately refreshing the
vendor tree; ordinary builds never run them. A refresh may resolve new transitive versions within
upstream ranges and must be reviewed with the resulting lock file and all changed ordinary files.

The project-local npm user/global configuration files and `tools/npm-shell.sh` expose the vendored
Hardhat CLI to the requested `npx hardhat compile` command. The wrapper changes only module
resolution, cache locations, telemetry, and release banners; the real Hardhat resolver, compilation
tasks, artifact generation, and native solc execution perform the build.
