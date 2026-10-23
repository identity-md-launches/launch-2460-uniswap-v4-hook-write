# Golden Cross and Bollinger Hooks

Two standalone Uniswap v4 hooks for Robinhood Chain (chain ID **4663**):
[`GoldenCrossHook`](contracts/GoldenCrossHook.sol) and [`BollingerHook`](contracts/BollingerHook.sol).
Each creates no token, pool, LP position, or depositor shares. The canonical implementations live in
`contracts/`; import-only entry points in `src/` preserve the existing Foundry and Hardhat source
roots without changing build configuration. There is one implementation and artifact per contract.
Bollinger does not inherit GoldenCross or combine its signal with another indicator.
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

`foundry.toml` pins the compiler, optimizer settings, and the existing project's fuzz seed:
`0x44c026aa94cf1f7f2d350042e578dcc53619d1c45a9e548e855f975dba844cc4`.
The additional requested seed is checked with:

```sh
forge test --offline --fuzz-seed 0x3a3258c3e9f8de3561577610cf566781b3afb476ac8a6593a22ac57d0a0fba7a
```

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

## Golden Cross signal (unchanged)

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

## Bollinger signal

[`SwapBollinger`](contracts/libraries/SwapBollinger.sol) implements a **20-observation SMA with
bands at two population standard deviations**. It uses the same final **sqrtPriceX96** observation
basis as the existing hook, before any strategy trade. This is an explicit compatibility assumption:
the bands apply to square-root prices, not to the squared token1/token0 exchange rate. One period
means one positive-output external swap, not a block or elapsed time. There is no EWMA, combined
signal, governance state machine, ratchet, or phase-flip rule.

For the most recent N samples (N = 20 once warm), the calculation is:

```text
SMA      = floor(sum(price) / N)
variance = floor((N * sum(price²) - sum(price)²) / N²)
sigma    = floor(sqrt(variance))
upper    = SMA + 2 * sigma
lower    = max(0, SMA - 2 * sigma)
```

The library subtracts the minimum sample before calculating variance; variance is invariant under
this translation. This preserves small fluctuations even near `uint160.max`. If the window's span
exceeds 123 bits, translated samples are right-shifted together by at most 37 bits before squaring;
the resulting sigma is shifted back. This is integer overflow protection for the same population
formula, not a different indicator. The SMA always uses the original full-precision samples.
In the scaled case, sigma differs from the real-valued sigma by less than two scaling units
(`2 * 2^shift` in X96 units); close-to-band comparisons inherit this quantization. Ordinary spans
below 2^123 need no scaling. `Math.sqrt` comes from the pinned OpenZeppelin library. Band outputs
are uint256 because an upper band may exceed uint160, and a negative lower band is clamped to zero.

- Observation 20 establishes the first full-window baseline without a trade; trading starts at 21.
- Each new price is compared with bands **including that sample**. Previous price at/inside/below
  the upper band followed by price strictly above its current upper band sells **token0 for token1**
  (`zeroForOne = true`, pending direction -1), moving the pool price lower.
- Previous price at/inside/above the lower band followed by price strictly below its current lower
  band sells **token1 for token0** (`zeroForOne = false`, pending direction +1), moving price higher.
- Equality does not cross. Remaining outside the same band does not issue another signal. Returning
  inside resets the relation; a later exit can trigger again. Opposite-band crossings replace pending
  directions. Bands do not set an execution target: treasury price limits bound the full-inventory sale.
- `bollingerBands(poolId)` returns the bands struct (`sma`, `standardDeviation`, `lower`, `upper`),
  sample count, observation count, and region (+1 above, -1 below, 0 inside/on). Partial-window bands
  are readable during warmup. Empty history returns zeros.
- Like Golden Cross, histories are isolated by full PoolId; zero-output swaps, liquidity actions,
  initialization, and the hook's own trades are not observations.

## Shared rebalance execution

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

The fee is **45 bps of actual gross swap output**, additional to the pool's LP fee:

```text
totalFee        = floor(grossOutput * 45 / 10_000)
creatorPart     = floor(grossOutput * 17 / 10_000)
charityPart     = floor(grossOutput * 3 / 10_000)
accumulatorPart = totalFee - creatorPart - charityPart
```

The 25-bps flywheel share goes to the existing external accumulator. It also receives the rounding
remainder (at most two units above `floor(grossOutput * 25 / 10_000)`). Outputs below 223 units incur zero fee. Native ETH and ordinary ERC-20 outputs work
in either direction.

For **exact input**, the positive `afterSwap` return deducts the fee from gross output, including
partial fills. Routers must enforce their minimum on the returned **net** output.

For **exact output**, `beforeSwap` reserves `floor(netRequested * 45 / 9_955)` output units and asks
the pool to produce `netRequested + reservedFee`. This makes the actual 45-bps fee exactly equal to
the reservation and preserves the requested net output. `afterSwap` captures that fee and returns
zero in the unspecified/input currency. Exact-output swaps that cannot produce all of the gross
output at the supplied price limit revert with `ExactOutputNotFilled`; oversized signed deltas are
rejected. There is no input-currency hook fee. This distinction follows v4's
[specified/unspecified currency accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting).

Fees accrue during `afterSwap` as **ERC-6909 claims on PoolManager held by the hook**, with separate
`creatorFees(currency)`, `accumulatorFees(currency)`, and `charityFees(currency)` liabilities. Minting claims needs no
immediate underlying transfer, and avoids making swaps depend on a fee recipient accepting ETH.
Anyone can call `redeemFees(currency, true)` for the creator or `redeemFees(currency, false)` for the
accumulator, or `redeemCharityFees(currency)` for the charity router. Redemption opens its own unlock, burns exactly those claims, and takes underlying to
the immutable recipient. It cannot redirect funds or spend strategy capital. A failed redemption
reverts atomically and leaves claims intact; the other recipients can still redeem separately. The charity router receives underlying currency by
transfer, without an assumed router ABI or additional callback; onward charitable routing is its responsibility.

**Strategy capital is separate from fee claims.** The brief specifies an external accumulator
address, so its 25-bps entitlement is not silently reinvested. Fund the hook with direct transfers of
the configured pool currencies; to reinvest fees, the accumulator first redeems and then transfers
them to the hook. All directly transferred balances are strategy capital, regardless of sender.
There are no individual deposits, withdrawal rights, shares, or promised returns. The treasury can
recover direct balances with `withdrawStrategy(currency, amount)`, exclusively to the accumulator.
That function cannot withdraw the fee claims. Do not send unrelated ERC-6909 claims to the hook.

## Deployment parameters

Both constructors have exactly six arguments, in this order:

| Argument | Purpose and responsibility |
| --- | --- |
| `IPoolManager manager` | The verified v4 PoolManager for chain 4663; immutable. |
| `address gasWallet` | Recorded operational wallet expected to pay for redemptions/retries; no special authority or automatic reimbursement. |
| `address accumulator` | Immutable beneficiary of the 25-bps flywheel fee and all recovered strategy capital. |
| `address governanceTreasury` | Immutable administrative authority for pool selection, price limits, and recovery to the accumulator. Prefer an operational multisig. |
| `address creatorWallet` | Immutable beneficiary of the 17-bps fee. |
| `address charityRouter` | Immutable beneficiary of the 3-bps charity fee; responsible for onward distribution. |

All six addresses must be explicit and nonzero. The treasury and fee recipients cannot be the
hook itself or its manager. Recipients must be able to receive the intended currencies; a recipient
that permanently rejects ETH cannot redeem its native fees. There is no recipient-change or
upgrade mechanism. Construction does not call outside contracts or require deployed code. Authority
never comes from `msg.sender` or `tx.origin`; a factory gains no administrative rights.

**PoolManager input:** the task's `0x8366a39cc670b4001a1121b8f6a443e40951` contains only 36 hex
digits and is not a valid 20-byte address. It has not been padded, guessed, or embedded in either hook.
PoolManager is an explicit constructor input, so this source-only task can be completed without
inventing a deployment value. Before deployment, the operator must obtain the intended full address
from the requester/official chain deployment record and verify chain ID 4663, code, and contract
identity. All recipient addresses are likewise supplied by the operator, never stand-ins.

### Permission address and salt

The enabled permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta`, and `afterSwapReturnDelta`. The lowest 14 address bits must be
**`0x20cc` (8396)**. BaseHook enforces this in the real constructor. No permissions can be changed.
Initialization returns the correct selector only through PoolManager and accepts ordinary static
LP fee tiers, including 3000 and 12500. It does not initialize or select a strategy pool itself.
No liquidity callbacks are enabled, so this hook cannot tax or gate LP withdrawals/fee collection.

[`script/MineHook.s.sol`](script/MineHook.s.sol) is a read-only helper. Its `run` function takes the
actual CREATE2 deployer address followed by the six constructor parameters. It returns the
predicted hook address, salt, and init-code hash using periphery's `HookMiner`. Call it through
`forge script` with signature `run(address,address,address,address,address,address,address)` and the seven
real deployment addresses. It reads no keys or environment and never broadcasts.

[`script/MineBollingerHook.s.sol`](script/MineBollingerHook.s.sol) provides the same interface for
Bollinger. An operator can dry-run either miner without a key or broadcast:

```sh
forge script script/MineBollingerHook.s.sol:MineBollingerHook \
  --sig 'run(address,address,address,address,address,address,address)' \
  "$CREATE2_DEPLOYER" "$POOL_MANAGER" "$GAS_WALLET" "$ACCUMULATOR" \
  "$TREASURY" "$CREATOR" "$CHARITY_ROUTER"
```

These names represent explicit operator-provided arguments; the script itself reads no environment
or keys. Actual deployment is the network deployer's responsibility after independent review.

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
   Golden Cross needs 200 observations and Bollinger needs 20 to establish a baseline; only a subsequent crossing trades.
5. Monitor `CrossDetected` / `BandCrossDetected`, `Rebalanced`, `RebalanceDeferred`, pending direction, inventory, and fee
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
for accounting proofs and remaining production review responsibilities. See [REVIEW.md](REVIEW.md) for local results and Slither findings, including inherited dependency
false positives. No live-chain fork, Mythril run, formal verification, independent audit, deployment,
or transaction broadcast is claimed by this deliverable.

## Migration from the previous source

The prior implementation charged 25 bps total (20 creator / 5 accumulator), despite this task's
wording that the total “remains” 45. The implemented total is the explicitly requested **45 bps**
(25 accumulator / 17 creator / 3 charity). Golden Cross's signal library, BaseHook inheritance,
pool selection, price limits, and rebalance behavior are unchanged. Its `src/GoldenCrossHook.sol`
import path continues to work through an import-only entry point.

Constructor calldata now needs the charity router as argument six, and the CREATE2 salt must be
recomputed. `FeeAccrued` now has a fifth field, `charityAmount`; update indexer event signatures.
Existing `redeemFees(currency, bool)` callers keep working. Charity claims have a separate
`redeemCharityFees(currency)` entry point. This change updates source only; existing on-chain
contracts are immutable and have not been modified, redeployed, or replaced.
