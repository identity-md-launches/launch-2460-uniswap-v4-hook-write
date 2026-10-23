# Local security review

This is the implementer's local review, not an independent audit. The supplied v4 security and
Ethereum security references were treated as review data. Production release still needs an
independent adversarial review and a fork rehearsal against the intended chain, pool, currencies,
recipients, and deployment factory. No live deployment is part of this work.

## Permissions and authority

The immutable address flags are `0x20cc`: initialization, before/after swap, and both swap-return
delta flags. BaseHook checks the address in its constructor and authenticates all external hook
callbacks against the immutable PoolManager. `unlockCallback` independently checks the manager
and consumes a commitment to the exact data of an outstanding hook-initiated unlock. Calling it
from a router, an EOA, or the manager with no outstanding operation fails.

`beforeSwapReturnDelta` is enabled solely to gross up exact-output trades by a bounded fee. It is
zero for exact-input trades. For exact output its specified delta is positive, at most
`floor(netRequested * 45 / 9955)`, and its unspecified delta is zero. It increases the pool's requested
output and never consumes, replaces, or cancels the swap. There is no NoOp route, caller-supplied
custom settlement, or administrative ability to change this calculation. A partial exact-output
fill reverts, so a reserved fee is never charged against an incomplete output.

The treasury is an explicit constructor argument. It can select one initialized pool, set execution
limits, and send direct strategy balances only to the immutable accumulator. It cannot change
fees, recipients, callback permissions, the chosen pool, or implementation. No upgrade, delegatecall,
selfdestruct, arbitrary external-call facility, approvals, or LP withdrawal restrictions are present.
The deployment factory and transaction origin have no implicit rights. Router `sender` and
`hookData` are not used for authorization, so no router identity allowlist is needed.

## Accounting review

Let `O` be gross external output and `F = floor(O * 45 / 10000)`.

| Operation | Hook PoolManager delta | Balancing action |
| --- | --- | --- |
| Fee capture | `+F` output from hook-return delta | `mint(hook, currencyId, F)` records `-F` and creates claims |
| Fee redemption | `+F` from burning the hook's claims | `take(currency, fixedRecipient, F)` records `-F` |
| Rebalance input | `-I` for actual input filled | `sync`, transfer/value, `settle` credits exactly `+I` |
| Rebalance output | `+R` for actual received output | `take(currency, hook, R)` records `-R` |

For exact input the fee delta is returned by `afterSwap`. For exact output the specified delta is
reserved by `beforeSwap`, while the afterSwap return is zero. If `N` is requested net output,
`F = floor(N * 45 / 9955)` and `O = N + F` imply `floor(O * 45 / 10000) = F`: the
remainder `N*45 - F*9955` lies in [0, 9954], and `O*45 = F*10000 + remainder`. Thus both modes capture exactly
the same output fee formula without charging input or using floating-point arithmetic.

Creator, accumulator, and charity liabilities sum to the claims minted for fees, per currency. Those claims
are never strategy balances. User swaps see net output and settle their own returned deltas;
rebalances settle only the hook's returned deltas. All four paths balance to zero at unlock end.
Real PoolManager integration tests and stateful invariants check this rather than assuming that a
mock swap implies valid settlement.

## Reentrancy, isolation, and failures

- Callback, redemption, retry, configuration, and recovery operations that reach outside contracts
  run under a reentrancy guard. `executeRebalance` requires a self-call inside that guard. The
  guard rejects a malicious recipient's nested swap in `beforeSwap`, as well as fee/retry reentry.
- Core's own-sender callback suppression prevents recursive fees and price observations. There
  is no user-controlled flag that disables fees or enables self-call privileges.
- Histories are keyed by the complete PoolId. Inventory is bound to one treasury-selected key,
  so another pool using either currency cannot spend or redirect it.
- An automatic rebalance's swap and settlement share one rollback boundary. Failed settlement
  restores its pool movement and inventory together, while keeping the triggering user trade.
  A partial fill retains input and a pending direction; an opposite crossover replaces that signal.
- Fee redemption clears the selected liability before external transfers. A revert restores it
  and the burned claims. Creator, accumulator, and charity redemptions are independent.
- Sums fit in uint256: 200 uint160 prices need fewer than 168 bits. The scaled short sum also fits.
  Returned fee deltas are bounded by the positive int128 gross output. Exact-output gross amounts
  are explicitly bounded before casting. Rebalance input is capped to int128.max and only a
  negative actual input delta is converted to an unsigned debt.
- There are no unbounded history loops in production, no environment/configuration reads on-chain,
  no block-number timing assumptions, no signatures, and no token-decimal assumptions.

## Residual economic and operational risks

The specified spot-price, swap-count signal is manipulable. Many cheap swaps in one transaction
can fill the window or create a crossover; a public rebalance can be sandwiched. Price limits bound
terminal execution but do not certify fair pricing or profitability. Only capital deliberately
assigned to this strategy should be exposed to it. Substituting a time window or an external oracle
would change the requested strategy and has not been done.

The treasury is trusted to choose the correct pool and execution limits. Broad limits increase
loss exposure; narrow/stale limits can leave a pending direction unfilled indefinitely. Pending
directions do not expire. There is no permissionless incentive payment: someone must fund gas for
redemptions and retries. Recipient addresses cannot be changed if their keys are lost or they reject
the currency. Recovery only works when the underlying token allows transfers.

The hook supports native ETH and conventional ERC-20 transfers, including no-return transfers
through v4's safe currency helper. It does not promise support for taxed/rebasing/upgradeable tokens.
A taxed strategy input is rejected when settlement credits less than the debt. Other token-specific
behavior, sequencer behavior, censorship, or pool-manager incompatibility requires chain-specific
review. Constructor validation deliberately does not assert external code identity on an empty
chain; deployment verification is an operator responsibility.

## Evidence and release responsibilities

The test suite covers successful exact-input/output swaps in both directions, nonzero fees and
redemptions, native ETH, a zero-ETH manager seeded with tokens only, crossover trading with real
liquidity, independent pool histories, no recursive observations, warmup and equality, circular
buffer eviction with a naive reference model, upper arithmetic bounds, partial fills, absent
liquidity, failed/taxed transfers, recipient reentry, fixed payout destinations, unauthorized entry,
CREATE2 salt mining, and liquidity removal/fee collection. Stateful tests assert token conservation,
claim/liability equality, and complete PoolManager settlement after randomized operations.

`forge build`, `forge test`, `forge fmt --check`, and the real `npx hardhat compile` are the local
validation commands. Native compiler versions and bytecode parity are also checked locally.
Compiler/Foundry lint heuristics may flag guarded external calls or bounded casts; the actual paths
and bounds are explained above. Slither was run for this revision; see [REVIEW.md](../REVIEW.md) for detector dispositions.
Mythril, formal verification, chain forks, external audits, and production gas benchmarking have not
been performed or represented as passed.

Before release, the deploying operator must resolve the malformed supplied PoolManager address and verify the intended full address,
chain 4663/Cancun compatibility, currency transfer behavior, fee-recipient reception, CREATE2
deployer and salt, intended PoolKey and liquidity, treasury policy for both limits, and monitoring.
An independent reviewer should specifically challenge oracle manipulation, the exact-output fee
reservation, failure rollback, and cross-pool inventory isolation.

## Bollinger arithmetic and signal review

Bollinger alone replaces the signal with a 20-slot ring, exact integer SMA, population variance,
and two standard deviations. It keeps the existing execution, settlement, permission, and isolation
patterns. The calculation uses the existing square-root-price basis; changing to arithmetic token
exchange prices would be a different deployment assumption. The newest sample participates in its
own band. The 20th establishes a baseline; same-side excursions do not repeatedly retrigger.

Centering all samples by their minimum is variance invariant. For spans at most 123 bits the
variance numerator fits: `N² * maxOffset² < 400 * 2^246 < 2^255`. Larger spans are normalized to
123 bits with a common shift, at most 37 bits for uint160 inputs. This avoids intermediate overflow
without imposing a pool price cap. Integer sigma rounds down before restoring the scale; precision
near a band is finite and documented. SMA uses unscaled samples. Upper bands use uint256 so that
`SMA + 2*sigma` cannot wrap/truncate. Negative lower bands become zero, consistent with nonnegative
price samples. Library functions are internal and have no deployment/link references.

The charity route mirrors other fee claims. The new action is appended to the unlock enum,
preserving the original action numbers; callback commitments, CEI, and the guard apply equally.
Native recipient rejection rolls back its redemption only; ERC-20 and native callback attempts
cannot reenter swaps or redemptions. Three-way fee liabilities equal the manager's minted claims.
The router must distribute received funds itself: this hook does not assume a donation method ABI.
