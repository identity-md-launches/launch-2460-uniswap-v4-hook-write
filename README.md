# Golden Cross Hook

A standalone Uniswap v4 hook for Robinhood Chain (chain ID **4663**). The deployable application is
[`GoldenCrossHook`](src/GoldenCrossHook.sol). It creates no token, pool, LP position, or depositor shares.
Mock tokens and a prefunded router live only in `test/`.

## Build and check offline

Requires Foundry with **Solidity 0.8.26** installed, and Node.js 20+ / npm on Linux x64 with glibc.
The project targets Cancun, as required by v4-core's transient accounting. All Solidity and JavaScript
dependencies needed for these commands are ordinary files in `lib/` and `vendor/`; no installation,
submodules, network access, or `node_modules/` directory is required.

```sh
forge build
forge test
forge fmt --check
npx hardhat compile
```

`foundry.toml` pins the compiler, optimizer settings, and the assignment's fuzz seed:
`0x44c026aa94cf1f7f2d350042e578dcc53619d1c45a9e548e855f975dba844cc4`.
Tests do not use RPCs, environment variables, FFI, or filesystem cheatcode permissions. Stateful
invariants run 64 sequences of 64 calls, including real PoolManager swaps and fee redemptions.

Hardhat **2.26.3** is vendored with a locked dependency resolver. Project-local npm configuration
exposes its CLI without installing packages. `hardhat.config.cjs` uses the same installed native
0.8.26 compiler as Foundry, located on `PATH` or through SVM's normal installation location. It
validates the compiler version and does not download one. No compiler binary is included. The
wrapper disables telemetry and release-banner requests and keeps caches inside this project.
`node tools/hardhat.cjs compile` and `npm run compile` are equivalent entry points.

The vendored Hardhat distribution supports compilation. Its optional-for-compilation EDR network
simulator is omitted to fit the 8 MiB source-bundle limit; use Foundry for tests and local EVM
execution. `hardhat node` and other commands that instantiate Hardhat Network require EDR and
are outside this offline distribution. The Solidity parser and all compilation dependencies remain
vendored.

The two builds produce identical hook creation bytecode with the supplied settings. Use a fresh
build when mining a deployment address. See [dependency provenance](DEPENDENCIES.md).

## Trading behavior and assumptions

Each pool has an independent 200-element ring buffer. A successful external swap with positive
output contributes the pool's final `sqrtPriceX96`, read through v4's `StateLibrary` **before** the
hook's own rebalance. The 50- and 200-swap sums are updated in constant time. These are arithmetic
means of the **square-root prices**, exactly as requested; they are neither squared prices nor
time-weighted averages. Token decimals are not assumed or normalized.

- The first 200 observations warm up the history. Observation 200 establishes a baseline and
  cannot trigger a trade. Partial-window averages are available for inspection during warmup.
- Subsequently, previous `SMA50 <= SMA200` followed by `SMA50 > SMA200` is a golden cross: sell
  the hook's token1 for token0 (`zeroForOne = false`). The reverse crossing sells token0 for token1.
- Equality alone does not trade. An equality-to-strict inequality transition can trigger a new
  signal. Comparisons use `4 * sum50` versus `sum200`, avoiding rounding-dependent decisions.
- Initialization, liquidity operations, zero-output swaps, and the hook's own swaps are excluded
  from the history. All ordinary external swaps count equally, including swaps in the same block.
- Only the treasury-configured strategy pool can spend the hook's balances. Other pools can use
  the hook for the same fee and independent history; they cannot trigger its strategy trades.

The strategy attempts to sell the entire available balance in the signaled input currency. It uses
an exact-input `poolManager.swap` inside the already-open unlock. Core suppresses a hook's callbacks
on its own swaps, so rebalances have no recursive observation or hook fee. The pool's normal LP fee
still applies. Proceeds stay in the hook for a later reverse crossover.

Both absolute square-root price limits must be configured. A partial fill pays only actual input,
retains unused input, and leaves the direction pending. A pending direction is retried on later
volume swaps in that pool or by `retryRebalance()`. An opposite crossover replaces it. A successful
full sale, or an empty input balance, clears it; new funding alone does not recreate a cleared signal.
Amounts exceeding `int128.max` are sold in bounded chunks, with the rest remaining pending.

An automatic attempt runs in an authenticated external self-call. An ordinary swap/settlement
failure rolls back that attempt, emits `RebalanceDeferred`, and preserves both the pending signal
and the triggering user trade. Explicit `retryRebalance()` bubbles failures to its caller. Extreme
gas exhaustion or a malicious currency can still make a transaction fail; this is not universal
protection against hostile tokens.

## Fees and capital ownership

The fee is **25 bps of actual gross swap output**, additional to the pool's LP fee:

```text
totalFee        = floor(grossOutput * 25 / 10_000)
creatorPart     = floor(grossOutput * 20 / 10_000)
accumulatorPart = totalFee - creatorPart
```

The accumulator receives the rounding remainder (less than one extra smallest unit over its exact
5-bps share). Outputs below 400 units incur zero fee. Native ETH and ordinary ERC-20 outputs work
in either direction.

For **exact input**, the positive `afterSwap` return deducts the fee from gross output, including
partial fills. Routers must enforce their minimum on the returned **net** output.

For **exact output**, `beforeSwap` reserves `floor(netRequested * 25 / 9_975)` output units and asks
the pool to produce `netRequested + reservedFee`. This makes the actual 25-bps fee exactly equal to
the reservation and preserves the requested net output. `afterSwap` captures that fee and returns
zero in the unspecified/input currency. Exact-output swaps that cannot produce all of the gross
output at the supplied price limit revert with `ExactOutputNotFilled`; oversized signed deltas are
rejected. There is no input-currency hook fee. This distinction follows v4's
[specified/unspecified currency accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting).

Fees accrue during `afterSwap` as **ERC-6909 claims on PoolManager held by the hook**, with separate
`creatorFees(currency)` and `accumulatorFees(currency)` liabilities. Minting claims needs no
immediate underlying transfer, and avoids making swaps depend on a fee recipient accepting ETH.
Anyone can call `redeemFees(currency, true)` for the creator or `redeemFees(currency, false)` for the
accumulator. Redemption opens its own unlock, burns exactly those claims, and takes underlying to
the immutable recipient. It cannot redirect funds or spend strategy capital. A failed redemption
reverts atomically and leaves claims intact; the other recipient can still redeem separately.

**Strategy capital is separate from fee claims.** The brief specifies an external accumulator
address, so its 5-bps entitlement is not silently reinvested. Fund the hook with direct transfers of
the configured pool currencies; to reinvest fees, the accumulator first redeems and then transfers
them to the hook. All directly transferred balances are strategy capital, regardless of sender.
There are no individual deposits, withdrawal rights, shares, or promised returns. The treasury can
recover direct balances with `withdrawStrategy(currency, amount)`, exclusively to the accumulator.
That function cannot withdraw the fee claims. Do not send unrelated ERC-6909 claims to the hook.

## Deployment parameters

The constructor has exactly the requested five arguments, in this order:

| Argument | Purpose and responsibility |
| --- | --- |
| `IPoolManager manager` | The verified v4 PoolManager for chain 4663; immutable. |
| `address gasWallet` | Recorded operational wallet expected to pay for redemptions/retries; no special authority or automatic reimbursement. |
| `address accumulator` | Immutable beneficiary of the 5-bps fee and all recovered strategy capital. |
| `address governanceTreasury` | Immutable administrative authority for pool selection, price limits, and recovery to the accumulator. Prefer an operational multisig. |
| `address creatorWallet` | Immutable beneficiary of the 20-bps fee. |

All five addresses must be explicit and nonzero. The treasury and fee recipients cannot be the
hook itself or its manager. Recipients must be able to receive the intended currencies; a recipient
that permanently rejects ETH cannot redeem its native fees. There is no recipient-change or
upgrade mechanism. Construction does not call outside contracts or require deployed code. Authority
never comes from `msg.sender` or `tx.origin`; a factory gains no administrative rights.

**Address correction:** the brief's `0x8366a39cc670b4001a1121b8f6a443e40951` contains only 36 hex
digits and is not a valid 20-byte address. It has not been padded or embedded in any contract.
The [official Uniswap deployment table](https://developers.uniswap.org/docs/protocols/v4/deployments)
lists **`0x8366a39CC670B4001A1121B8F6A443A643e40951`** for Robinhood Chain 4663. This is the published
full address, not a live-chain verification from this assignment. The deployer must verify the
chain ID, runtime code, and intended deployment before supplying the constructor argument.

### Permission address and salt

The enabled permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta`, and `afterSwapReturnDelta`. The lowest 14 address bits must be
**`0x20cc` (8396)**. BaseHook enforces this in the real constructor. No permissions can be changed.
Initialization returns the correct selector only through PoolManager and accepts ordinary static
LP fee tiers, including 3000 and 12500. It does not initialize or select a strategy pool itself.
No liquidity callbacks are enabled, so this hook cannot tax or gate LP withdrawals/fee collection.

[`script/MineHook.s.sol`](script/MineHook.s.sol) is a read-only helper. Its `run` function takes the
actual CREATE2 deployer address followed by the five constructor parameters. It returns the
predicted hook address, salt, and init-code hash using periphery's `HookMiner`. Call it through
`forge script` with signature `run(address,address,address,address,address,address)` and the six
real deployment addresses. It reads no keys or environment and never broadcasts.

Mine using the exact bytecode, deployer, and constructor arguments that will be deployed. Changing
any of these changes the address and invalidates the salt. Recheck address availability on the
target chain and deploy through that CREATE2 deployer. The helper is tested by actually deploying
the hook with its returned salt. This repository has no launch manifest and broadcasts nothing.

## After launch

1. An external operator initializes/provides liquidity to the intended pool. This project supplies
   the hook only. The hook does not restrict which factory calls initialization through PoolManager.
2. The `governanceTreasury` calls `configureStrategy(PoolKey, sell0LimitX96, sell1LimitX96)` once.
   Obtain the full key from the intended pool's on-chain `Initialize` event/official pool record;
   it includes both ordered currencies, fee, tick spacing, and this hook address. It must already
   be initialized. Neither first use nor an attacker can select the strategy pool. Rebinding is
   permanently disabled after configuration.
3. Choose absolute price limits from the treasury's approved execution/risk policy. They must be
   strictly inside TickMath bounds, with `sell0Limit < currentPrice < sell1Limit` when configured.
   No guessed default price limits are supplied. `setPriceLimits` can update them later under the
   same validation. Selection/retries fail clearly while unconfigured; ordinary pool swaps can
   still accrue fees/history. Existing history is preserved when the pool is selected.
4. Fund the hook with the intended strategy balances only after checking the pool and limits.
   Funding is irrevocably subject to the strategy and treasury's fixed-destination recovery power.
   The first 200 observations establish history; only a subsequent crossing trades.
5. Monitor `CrossDetected`, `Rebalanced`, `RebalanceDeferred`, pending direction, inventory, and fee
   liabilities. Pay transaction gas for periodic redemptions and any needed retries. Redemptions and
   explicit retries require a fresh PoolManager unlock and cannot be called inside an existing one.
6. If liquidity or token transfers become unavailable, review the pending signal and limits before
   retrying. A pending signal has no time expiry. The treasury can withdraw capital to the accumulator
   when the token permits transfers; it cannot freeze user swaps or LP removals.

## Security and verification scope

This strategy deliberately uses **swap-count spot observations**. An attacker can manufacture
observations, create a crossover, or sandwich a predictable rebalance. It is not a manipulation-safe
oracle or a guarantee of profitable execution. Absolute price limits bound execution, but do not
establish fair value, prevent repeated manipulation, or replace an independent oracle. No extra
oracle, timing rule, or keeper discretion has been invented to change the requested signal.

Only ordinary ERC-20 transfers and native ETH are supported. Fee-on-transfer, rebasing, blocked,
upgradeable, or adversarial currency behavior needs separate token-specific review. Settlement
checks reject an input transfer that credits the manager by less than the amount owed.

Tests use a real vendored PoolManager and cover exact input/output in both directions, ring-buffer
reference fuzzing, warmup/equality, cross-triggered trades, native funding, a fresh token-only pool,
partial fills, failed transfers, no liquidity, unauthorized callbacks, unexpected unlocks, malicious
recipient callbacks, fee conservation, and CREATE2 deployment. See [the security review](docs/SECURITY.md)
for accounting proofs and remaining production review responsibilities. No live-chain fork,
Slither/Mythril run, formal verification, independent audit, deployment, or transaction broadcast is
claimed by this deliverable.
