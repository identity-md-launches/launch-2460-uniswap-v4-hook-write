# RSIHook

`contracts/RSIHook.sol` is a standalone Uniswap v4 hook using the existing Golden Cross hook's
BaseHook, fee-claim, pool-selection, price-limit and settlement patterns. Its only indicator is
the 14-period Wilder RSI in `contracts/libraries/SwapRSI.sol`. All library functions are internal;
deployment requires no library linking. `src/RSIHook.sol` is an import-only build entry point.
No existing hook, build configuration or dependency is changed.

## Observation and signal assumptions

One period means one successful external swap with positive gross output, including multiple
swaps within one transaction or block. Each pool has independent history, keyed by the full PoolId.
The observation is the pool's post-swap **sqrtPriceX96**, read before the hook's own rebalance.
This deliberately matches GoldenCrossHook's observation basis: RSI is computed on square-root
prices, not on squared token1/token0 exchange rates or candles. Neither token decimals nor time
intervals are assumed. RSI of a nonlinear price transformation differs from RSI of the exchange
rate; clients must use this same basis to reproduce the signal.

Initialization, liquidity changes, zero-output swaps and the hook's own swaps are excluded.
PoolManager suppresses callbacks for a hook's own swap. No caller-supplied price or hookData feeds
the indicator, and no block-number or timestamp logic is used.

For each change, `gain = max(price - previousPrice, 0)` and
`loss = max(previousPrice - price, 0)`. The standard calculation is:

```text
Initial averageGain = sum(first 14 gains) / 14
Initial averageLoss = sum(first 14 losses) / 14
Next averageGain    = (13 * previousAverageGain + gain) / 14
Next averageLoss    = (13 * previousAverageLoss + loss) / 14
RSI                 = 100 * averageGain / (averageGain + averageLoss)
```

The first price establishes the previous price; **15 prices are needed for 14 changes**. No
trade occurs before that. The first full RSI can trade immediately. All gains and no losses
produce RSI 100; all losses and no gains produce 0. When both averages are zero, the chosen
convention is neutral RSI 50. A zero change contributes zero to both averages.

The library keeps 14 times each average with 64 fractional bits. The initial sums are exact;
the later equivalent update is `sum = floor(13 * sum / 14) + change`. Keeping scaled sums avoids
an early seed division and preserves tiny moves even at large uint160 prices. All intermediate
values fit uint256 over the full uint160 input domain. The two smoothed sums underestimate exact
arithmetic by less than 14 Q64 units each, equivalent to less than `2^-64` raw price units in
each average. Strict comparisons account for that error conservatively, so rounding alone
cannot turn exact 30 or 70 into a trade. Conditions inside this tiny uncertainty interval are
neutral. After sufficiently long runs of unchanged prices, finite-precision averages can decay
to zero, at which point the flat-history convention applies.

| Condition | Direction | Rebalance |
| --- | --- | --- |
| RSI > 70 | -1 | Sell the hook's token0 for token1 (`zeroForOne = true`), moving price lower. |
| RSI < 30 | +1 | Sell the hook's token1 for token0 (`zeroForOne = false`), moving price upper. |
| 30 <= RSI <= 70, or warmup | 0 | No strategy trade. |

The condition is evaluated on **every** ready observation, without a crossing requirement.
An unchanged overbought/oversold condition can trade new inventory. There is no separate EWMA,
other signal, governance state machine, ratchet, hysteresis or phase flip.

`rsi(poolId)` returns `(valueBps, changes, observations, direction)`. `valueBps` is RSI rounded
down in hundredths of a point: 7000 means 70. It is zero during warmup, so use `changes == 14`
to distinguish a ready RSI of zero from an unready history. `direction` uses the unrounded ratio
with the rounding bound above; a displayed 7000 can therefore have direction -1. `PriceObserved`
is emitted for each qualifying sample; `RSIUpdated` is emitted for each ready RSI, including neutral.

## Rebalance execution and fees

Only the treasury-selected pool can spend strategy inventory. The hook attempts a full-inventory
exact-input sale, bounded by the treasury's absolute sqrt-price limit and `int128.max` per attempt.
These limits bound execution; the strategy does not target RSI 50 or manage liquidity positions.
Only actual input filled is paid, and proceeds remain in the hook. The ordinary pool LP fee applies.

Automatic failures roll back the inner swap and settlement, emit `RebalanceDeferred`, and preserve
the user's swap and pending direction. Partial fills retain unused inventory and stay pending.
Each later qualifying observation of the strategy pool **replaces** that direction, including
canceling it when neutral. Observations from other pools cannot cancel or execute it. Full fills
or empty inventory clear pending status. Anyone may call `retryRebalance()` using the most recent
pending condition; explicit retry failures revert. A retry is not an observation and has no time
expiry. The most recent RSI may predate the hook's own trade or other zero-output price movement.

The fee is **45 bps of gross output**, in addition to the pool LP fee:

```text
totalFee        = floor(grossOutput * 45 / 10000)
creatorPart     = floor(grossOutput * 17 / 10000)
charityPart     = floor(grossOutput * 3 / 10000)
accumulatorPart = totalFee - creatorPart - charityPart
```

The flywheel accumulator receives 25 bps plus rounding residue (at most two smallest currency
units). Exact-input swaps return net output after the fee. Exact-output swaps reserve
`floor(netRequested * 45 / 9955)` extra output in beforeSwap and preserve the requested net output;
partial exact-output fills revert atomically. These are the same accounting rules as Golden Cross.

Fees are segregated ERC-6909 claims held on PoolManager, not spendable strategy inventory. Anyone
can redeem them to the immutable destinations with `redeemFees(currency, true)` (creator),
`redeemFees(currency, false)` (accumulator), and `redeemCharityFees(currency)` (charity router).
An ETH-rejecting recipient cannot block swaps or the other recipients' redemptions. Failed
redemptions leave claims intact. The charity router receives a currency transfer, without any
assumed router ABI; it handles onward distribution.

Strategy capital comes from direct currency transfers to the hook. Reinvesting flywheel fees
requires the accumulator to redeem and transfer them back. Direct transfers issue no shares or
depositor claims. Treasury recovery sends direct balances only to the fixed accumulator and
cannot withdraw fee claims.

## Deployment parameters

Target chain: **Robinhood Chain, chain ID 4663**, with the existing Cancun EVM build settings.
The constructor takes exactly six arguments, in order:

| Argument | Operator supplies |
| --- | --- |
| `IPoolManager manager` | The full, verified Uniswap v4 PoolManager address for chain 4663. |
| `address gasWallet` | Operational wallet for paying retries/redemptions; no exclusive powers or reimbursement. |
| `address accumulator` | Recipient of flywheel fees and recovered strategy capital. |
| `address treasury` | Authority to select one pool, set price limits and recover capital to the accumulator. |
| `address creatorWallet` | Recipient of the 17-bps fee. |
| `address charityRouter` | Recipient responsible for distributing the 3-bps charity fee. |

All must be explicit and nonzero. The treasury and recipients cannot be the hook or manager.
No default recipient, deployer-owned authority, key, RPC, live pool or deployment address is
invented. The constructor calls no external contract and does not require code at those addresses.
Authority is derived from the explicit treasury argument, never the deploying factory or tx.origin.
RSI exposes `treasury()`, whereas the older hooks call this getter `governanceTreasury()`.

**Address issue in the brief:** `0x8366a39cc670b4001a1121b8f6a443e40951` contains 36 hex digits,
not the 40 required for a full address. It is neither padded nor embedded. The deployer must obtain
the intended complete address from the requester or authoritative chain deployment record and
verify chain ID, runtime code and contract identity before deployment. No live verification or
transaction is claimed here. The explicit constructor parameter keeps the source deliverable usable.

The enabled permissions are beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta and
afterSwapReturnDelta. The low 14 deployment-address bits must equal **0x20cc**. BaseHook validates
this in the real constructor. `script/MineRSIHook.s.sol:MineRSIHook` exposes the read-only function:

```text
run(create2Deployer, manager, gasWallet, accumulator, treasury, creatorWallet, charityRouter)
  -> (predictedHookAddress, salt, initCodeHash)
```

Supply the actual deployer and six constructor addresses. The helper reads no environment or
keys and does not broadcast. Use the exact compiler settings, bytecode and arguments that will
be deployed, and check the predicted address is available on the target chain. Tests perform a
real CREATE2 deployment with its output. Deploying this hook does not deploy a token or pool.

## After launch

1. The operator supplies the initialized pool's complete key from its Initialize event or official
   record (ordered currencies, fee, tick spacing, this hook). Treasury calls
   `configureStrategy(key, sell0LimitX96, sell1LimitX96)` exactly once. Until configured, pool
   swaps accrue history and fees but cannot spend strategy balances. Configuration preserves
   history and does not itself trade. A wrong pool choice cannot be rebound.
2. Treasury supplies both limits from its execution policy, strictly inside TickMath's bounds,
   with `sell0Limit < currentSqrtPrice < sell1Limit`. `setPriceLimits` updates them under the same
   validation. No assumed defaults exist. Both configuration and updates emit events.
3. Fund only the intended strategy currencies after verifying configuration and transfer behavior.
   The next qualifying swap may trigger a trade immediately if 15 observations already exist.
4. Monitor RSIUpdated, pendingDirection, Rebalanced, RebalanceDeferred, fee liabilities and balances.
   Anyone, normally gasWallet, can pay for redemptions and retries. They need a fresh PoolManager
   unlock, so cannot run inside an already-open unlock. Review limits, liquidity and the age of
   the last observation before retrying.
5. Treasury can call `withdrawStrategy(currency, amount)` to recover direct balances to accumulator.
   It cannot redirect fees, change recipients or indicator parameters, pause swaps, control LP
   withdrawals, or upgrade this contract. There is no governance or ownership-transfer mechanism.

## Verification and remaining risks

The existing build configuration is `hardhat.config.cjs` (there is no hardhat.config.js).
It stays unchanged. Both builds use Solidity 0.8.26, v4-core 1.0.2, v4-periphery 1.0.3 and
OpenZeppelin 5.0.2; the existing offline CLI runs Hardhat 2.26.3. No installation is required.

```sh
forge build
forge test
forge test --fuzz-seed 0x6bd9a8ed6933fd9ca8a8a6fed4d31a2dbe35df13b0765f8169db049e785613de
forge fmt --check
npx hardhat compile
```

Local results for this addition:

| Check | Result |
| --- | --- |
| `forge build` | Pass with Solidity 0.8.26; existing SwapSMA cast lint warnings remain. |
| `forge test` with the pinned seed | 158 passed, 0 failed, 0 skipped across 13 suites. |
| `forge test` with the assignment seed above | 158 passed, 0 failed, 0 skipped across 13 suites. |
| `forge fmt --check` (also checked new contracts explicitly) | Pass. |
| `npx hardhat compile` | 41 Solidity files compiled successfully for Cancun. |
| Build artifact comparison | Foundry and Hardhat creation/runtime bytecode match; no link references. |
| Constructor and size | Six address arguments; RSIHook runtime is 13,703 bytes. |

The default tests use the seed already pinned in foundry.toml. The additional command checks the
assignment's supplied seed too. Tests do not read or write environment variables, use a fork,
load keys, or require network access. The RSI suites cover known Wilder values, an exact rational
reference, full-range arithmetic, warmup, equality/rounding, every-observation triggering, neutral
cancellation, real PoolManager trades, exact input/output and partial fills, both ERC-20 and native
currencies, recipient failures, reentrancy, invalid configuration/callbacks, and conservation of
claims and tokens. Stateful invariants interleave trades and redemptions with funded strategy capital.

Swap-count spot prices are manipulable: an attacker can manufacture observations and sandwich
rebalances. The 14-period indicator and absolute limits do not establish fair value or profitability.
Retrying a stale observation, allowing repeated signals and using an immutable treasury/recipient
configuration are operational risks. Supported currencies must have ordinary transfer/balance
semantics; taxed, rebasing, paused, blocklisted or adversarial currencies need separate review.
Input settlement mismatches revert the inner strategy attempt. Gas exhaustion or hostile token
behavior can still fail the outer swap.

This is source work with local tests, not a deployment or independent audit. A separate adversarial
review of the strategy, currencies, exact deployment parameters and live chain support remains the
deployer's responsibility before funding. No Slither, Mythril or live-chain fork run is claimed for
this addition.
