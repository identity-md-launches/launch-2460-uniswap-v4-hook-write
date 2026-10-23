# Implementation review

This is the implementer's local review, not an independent audit. It covers the requested Bollinger
hook and Golden Cross charity-fee change. No contracts were deployed and no live-chain results are
claimed. The network's independent review remains a release responsibility.

## Scope and assumptions

- Canonical implementations are `contracts/BollingerHook.sol`, `contracts/GoldenCrossHook.sol`,
  and `contracts/libraries/SwapBollinger.sol`. Import-only `src/` entry points retain both existing
  build roots. Existing configuration, dependency sources, and lockfiles are unchanged.
- A source comparison against the original Golden Cross implementation confirms that its SMA
  library, pool configuration, hook permissions/inheritance, and rebalance behavior are unchanged.
  Its edits are the sixth constructor argument, charity validation/storage/claims/redemption,
  fee constants and split, extended fee event, and the import path needed for the requested layout.
- Both hooks charge 45 bps of gross output: 17 creator, 3 charity, and the remainder (25 bps plus
  integer dust) to the accumulator. This explicitly supersedes the original source's 25-bps total.
- Bollinger uses the existing `sqrtPriceX96` observation basis. Periods are positive-output swaps.
  It includes the latest sample, uses population variance, warms up for 20 samples, and responds to
  subsequent strict band crossings. Bounds and integer normalization are documented in README.
- Six real deployment addresses must be supplied. The PoolManager value in the task has 36 hex
  digits and cannot be used as an address. No padded value, alternative address, or guessed recipient
  was put in the code. This does not prevent a constructor-based source implementation.

## Validation

The following checks ran locally with Solidity 0.8.26 and the existing Cancun/optimizer settings:

| Check | Result |
| --- | --- |
| `forge build --offline --sizes` | Successful; both hooks within deployment limits |
| `forge test --offline --fuzz-runs 512` | 98 tests passed; existing pinned seed |
| Requested seed `0x3a3258c3e9f8de3561577610cf566781b3afb476ac8a6593a22ac57d0a0fba7a` | 98 tests passed in the final clean export, 256 fuzz runs |
| `forge fmt --check` and `forge fmt --check contracts` | Passed |
| `npx hardhat compile --force` | 38 Solidity files compiled successfully |
| Hardhat versus Foundry creation bytecode | Identical for each of the two hooks |
| Protected configuration/dependency diff and whitespace checks | No changes/errors |

A fresh source export containing all tracked and new deliverable files, without `.git`, pinned
reads, build outputs, or caches, independently passed `forge build --offline --sizes`, the requested
seed's full test suite, both formatting checks, and `npx hardhat compile` (38 files). Its High-only
Slither pass reproduced the same six findings below. The compressed source bundle was 6.41 MB.
Git metadata was not edited; the network can collect the ordinary source changes for submission.

| Contract | Runtime bytes | Initcode bytes |
| --- | ---: | ---: |
| GoldenCrossHook | 13,653 | 15,025 |
| BollingerHook | 14,470 | 15,842 |

Coverage includes both exact-input and exact-output directions, small-output rounding, all six zero
constructor arguments, forbidden charity destinations, native and ERC-20 redemptions, rejecting and
reentrant recipients, callback impersonation, real CREATE2 deployment and permission validation,
strategy setup/access checks, warmup, upper/lower crossings, same-side suppression, partial fills,
opposite signals, no liquidity, failed/taxed transfers, retry, cross-pool isolation, and LP operations.

Library tests compare the 20-slot ring and crossings against a separate uncentered variance model,
exercise hand-calculated vectors, equality, negative lower bands, uint160 extremes, small volatility
near uint160.max, and full-range two-point distributions. Each hook has its own stateful handler:
64 runs of 64 swaps/redemptions check token conservation, ERC-6909 claims versus all three fee
liabilities, and zero outstanding manager deltas. Tests need no environment, RPC, files, or FFI.

## Slither findings and disposition

**Slither did not pass its zero-High gate.** The unfiltered High pass returned six findings. Running
the identical command against a clean export of the original commit reproduced four of them.
The other two are the same history-alias pattern in Bollinger and an intentional XOR in the newly
referenced, protected OpenZeppelin Math library. No suppression comments, detector configuration,
dependency replacement, or unrelated Golden Cross changes were introduced to conceal them.

| Severity / detector | Count | Disposition and evidence |
| --- | ---: | --- |
| High: `incorrect-exp` | 2 | `FullMath.mulDiv` and `Math.mulDiv` deliberately use `(3 * denominator) ^ 2` as a four-bit modular-inverse seed, not exponentiation. `DependencyMathTest` checks full-width exact quotients against `a*b/b = a`, including wide products and odd divisors. v4's instance is present in the baseline. |
| High: `incorrect-shift` | 2 | Protected v4 `BitMath` uses data-dependent shifts of constant lookup tables. These are intentional lookup operations, not reversed numeric operands. Tests cover every single-bit position and randomized words against simple independent MSB/LSB loops. Both reports occur on the baseline. |
| High: `uninitialized-state` | 2 | Solidity initializes both history mappings to zero; internal library `push` writes through a storage reference. Slither misses those alias writes. Actual PoolManager swaps and independent ring tests prove nonzero persisted observations and window state. Golden Cross has the same baseline report. |
| Medium: `divide-before-multiply` | 20 | Protected math performs exact factor-of-two division/modular inversion, tick quantization, reciprocal fixed-point arithmetic, or ABI word rounding. These reports concern intentional dependency arithmetic, not the hook's fee multiplication. |
| Medium: `reentrancy-no-eth` | 2 | `executeRebalance` requires `msg.sender == address(this)` and an already-entered guard. All paths that establish that guard are authenticated/nonReentrant. Pending direction is cleared only after the actual fill is known. Token/native callback tests demonstrate rejection of nested swaps and redemptions. |
| Medium: `uninitialized-local` | 4 | Three Bollinger uint256 sums and the dependency's `hookDelta` have Solidity-defined zero defaults. Empty, one-sample, constant, and reference-vector behavior exercise this initialization. |
| Medium: `unused-return` | 16 | Slot0 reads intentionally use only price; the other fields are not inputs to this strategy. Unlock return bytes are empty by design and the consumed commitment is checked. Dependency hook-call selectors are checked by `callHook`; its returned bytes are unnecessary for those callbacks. |

The combined High/Medium invocation returned 50 findings (6 High, 44 Medium) and exited nonzero.
The classifications above are local dispositions, not an assertion that an automated verifier will
waive them. The task prohibits changes to these dependencies and requires Golden Cross's unrelated
logic to stay unchanged. A verifier that rejects every raw High will still reject this tree; that
constraint cannot honestly be represented as satisfied.

## Remaining operational review

Both signals deliberately use manipulable swap-count spot observations and can be manufactured or
sandwiched. Treasury-set absolute price limits constrain execution but do not establish fair value.
The treasury controls strategy configuration/limits and recovery to the fixed accumulator. Fee
beneficiaries are immutable, claims are separate from strategy inventory, and charity onward routing
belongs to the recipient. There is no automatic reimbursement for keepers or expiration of pending
directions. Review the actual currencies, complete manager address, strategy pool, recipient behavior,
price limits, and CREATE2 deployment inputs before release. See README and `docs/SECURITY.md`.
