// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SwapSMA} from "./libraries/SwapSMA.sol";

/// @notice A swap-count SMA strategy with a fixed output fee. No token, pool, or LP position is created.
/// @dev Exact-input fees use the afterSwap output delta. Exact-output fees reserve a specified delta
/// in beforeSwap, then mint output claims in afterSwap; exact-output partial fills revert.
/// Fee claims belong to the two recipients; strategy capital consists only of this hook's own balances.
contract GoldenCrossHook is BaseHook, IUnlockCallback, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using SwapSMA for SwapSMA.History;

    uint256 public constant FEE_BPS = 25;
    uint256 public constant CREATOR_BPS = 20;
    uint256 public constant ACCUMULATOR_BPS = 5;
    uint256 private constant BPS = 10_000;

    address public immutable gasWallet;
    address public immutable accumulator;
    address public immutable governanceTreasury;
    address public immutable creatorWallet;

    mapping(PoolId => SwapSMA.History) private _histories;
    mapping(Currency => uint256) public creatorFees;
    mapping(Currency => uint256) public accumulatorFees;

    PoolKey private _strategyKey;
    PoolId public strategyPoolId;
    bool public strategyConfigured;
    uint160 public sellToken0LimitX96;
    uint160 public sellToken1LimitX96;
    int8 public pendingDirection;
    bytes32 private _unlockCommitment;

    enum Action {
        RedeemCreator,
        RedeemAccumulator,
        RetryRebalance
    }

    error ZeroAddress();
    error InvalidRecipient();
    error OnlyTreasury();
    error OnlySelf();
    error InvalidPool();
    error PoolNotInitialized();
    error StrategyNotConfigured();
    error StrategyAlreadyConfigured();
    error InvalidPriceLimits();
    error ExactOutputNotFilled();
    error AmountTooLarge();
    error UnexpectedCallback();
    error NothingToRedeem();
    error NoPendingRebalance();
    error PriceLimitReached();
    error NoFill();
    error InvalidSwapDelta();
    error SettlementMismatch();
    error InvalidAmount();

    event StrategyConfigured(PoolId indexed poolId, uint160 sell0LimitX96, uint160 sell1LimitX96);
    event PriceLimitsUpdated(uint160 sell0LimitX96, uint160 sell1LimitX96);
    event PriceObserved(PoolId indexed poolId, uint64 observation, uint160 sqrtPriceX96);
    event CrossDetected(PoolId indexed poolId, int8 direction, uint160 sma50, uint160 sma200);
    event FeeAccrued(
        PoolId indexed poolId, Currency indexed currency, uint256 creatorAmount, uint256 accumulatorAmount
    );
    event FeesRedeemed(Currency indexed currency, address indexed recipient, uint256 amount);
    event Rebalanced(
        PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 remainingIn
    );
    event RebalanceDeferred(PoolId indexed poolId, int8 direction, bytes32 reasonHash);
    event RebalanceEmpty(PoolId indexed poolId, int8 direction);
    event StrategyWithdrawn(Currency indexed currency, uint256 amount);

    modifier onlyTreasury() {
        if (msg.sender != governanceTreasury) revert OnlyTreasury();
        _;
    }

    constructor(
        IPoolManager manager,
        address gasWallet_,
        address accumulator_,
        address governanceTreasury_,
        address creatorWallet_
    ) BaseHook(manager) {
        if (
            address(manager) == address(0) || gasWallet_ == address(0) || accumulator_ == address(0)
                || governanceTreasury_ == address(0) || creatorWallet_ == address(0)
        ) revert ZeroAddress();
        // A recipient must be external to this hook/manager, so fees cannot become strategy capital by accident.
        if (
            accumulator_ == address(this) || creatorWallet_ == address(this)
                || accumulator_ == address(manager) || creatorWallet_ == address(manager)
                || governanceTreasury_ == address(this) || governanceTreasury_ == address(manager)
        ) revert InvalidRecipient();
        gasWallet = gasWallet_;
        accumulator = accumulator_;
        governanceTreasury = governanceTreasury_;
        creatorWallet = creatorWallet_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Binds all strategy capital to one already initialized pool, once, under treasury control.
    /// @dev Other pools may use the fee/oracle hook but can never spend strategy balances.
    function configureStrategy(PoolKey calldata key, uint160 sell0Limit, uint160 sell1Limit)
        external
        onlyTreasury
        nonReentrant
    {
        if (strategyConfigured) revert StrategyAlreadyConfigured();
        if (address(key.hooks) != address(this) || key.currency0 >= key.currency1) revert InvalidPool();
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price == 0) revert PoolNotInitialized();
        _validateLimits(sell0Limit, sell1Limit, price);
        _strategyKey = key;
        strategyPoolId = key.toId();
        strategyConfigured = true;
        sellToken0LimitX96 = sell0Limit;
        sellToken1LimitX96 = sell1Limit;
        emit StrategyConfigured(strategyPoolId, sell0Limit, sell1Limit);
    }

    function setPriceLimits(uint160 sell0Limit, uint160 sell1Limit) external onlyTreasury nonReentrant {
        if (!strategyConfigured) revert StrategyNotConfigured();
        (uint160 price,,,) = poolManager.getSlot0(strategyPoolId);
        _validateLimits(sell0Limit, sell1Limit, price);
        sellToken0LimitX96 = sell0Limit;
        sellToken1LimitX96 = sell1Limit;
        emit PriceLimitsUpdated(sell0Limit, sell1Limit);
    }

    function strategyKey() external view returns (PoolKey memory) {
        if (!strategyConfigured) revert StrategyNotConfigured();
        return _strategyKey;
    }

    /// @notice Partial-window averages are available during warmup, but trading starts after 200 observations.
    function movingAverages(PoolId id)
        external
        view
        returns (uint160 sma50, uint160 sma200, uint16 count, uint64 observations, int8 relation)
    {
        SwapSMA.History storage h = _histories[id];
        (sma50, sma200) = h.averages();
        return (sma50, sma200, h.count, h.observations, h.relation);
    }

    /// @notice Anyone can redeem one recipient's fee claims; the destination is immutable.
    /// @dev Separating redemptions prevents an ETH-rejecting recipient from blocking ordinary swaps.
    function redeemFees(Currency currency, bool forCreator) external nonReentrant {
        if ((forCreator ? creatorFees[currency] : accumulatorFees[currency]) == 0) revert NothingToRedeem();
        _unlock(abi.encode(forCreator ? Action.RedeemCreator : Action.RedeemAccumulator, currency));
    }

    /// @notice Anyone, including the named gas wallet, can retry a pending signal after liquidity/limits improve.
    function retryRebalance() external nonReentrant {
        if (!strategyConfigured) revert StrategyNotConfigured();
        if (pendingDirection == 0) revert NoPendingRebalance();
        _unlock(abi.encode(Action.RetryRebalance, _strategyKey.currency0));
    }

    /// @notice Treasury may recover strategy capital/donations only to the accumulator.
    /// @dev This cannot withdraw fee claims, change fee recipients, or touch anyone's LP position.
    function withdrawStrategy(Currency currency, uint256 amount) external onlyTreasury nonReentrant {
        if (amount == 0 || amount > currency.balanceOfSelf()) revert InvalidAmount();
        currency.transfer(accumulator, amount);
        emit StrategyWithdrawn(currency, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (_unlockCommitment == bytes32(0) || keccak256(data) != _unlockCommitment) {
            revert UnexpectedCallback();
        }
        delete _unlockCommitment;
        (Action action, Currency currency) = abi.decode(data, (Action, Currency));
        if (action == Action.RetryRebalance) {
            // Unlike automatic attempts, an explicit retry bubbles failures up to its caller.
            this.executeRebalance();
        } else {
            bool forCreator = action == Action.RedeemCreator;
            uint256 amount = forCreator ? creatorFees[currency] : accumulatorFees[currency];
            address recipient = forCreator ? creatorWallet : accumulator;
            if (forCreator) delete creatorFees[currency];
            else delete accumulatorFees[currency];
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, recipient, amount);
            emit FeesRedeemed(currency, recipient, amount);
        }
        return "";
    }

    /// @dev External only to provide an atomic rollback boundary for automatic rebalances.
    /// PoolManager is already unlocked here; never nest unlock inside afterSwap.
    function executeRebalance() external {
        if (msg.sender != address(this) || !_reentrancyGuardEntered()) revert OnlySelf();
        int8 direction = pendingDirection;
        if (direction == 0) revert NoPendingRebalance();
        bool zeroForOne = direction < 0;
        PoolKey memory key = _strategyKey;
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 balance = input.balanceOfSelf();
        if (balance == 0) {
            pendingDirection = 0;
            emit RebalanceEmpty(strategyPoolId, direction);
            return;
        }
        uint160 limit = zeroForOne ? sellToken0LimitX96 : sellToken1LimitX96;
        (uint160 price,,,) = poolManager.getSlot0(strategyPoolId);
        if (zeroForOne ? price <= limit : price >= limit) revert PriceLimitReached();
        uint256 amount =
            balance > uint256(uint128(type(int128).max)) ? uint256(uint128(type(int128).max)) : balance;

        // Core suppresses this hook's callbacks on its own swap, avoiding recursive fees and observations.
        BalanceDelta delta = poolManager.swap(key, SwapParams(zeroForOne, -int256(amount), limit), "");
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta == 0 || outputDelta == 0) revert NoFill();
        if (inputDelta > 0 || outputDelta < 0) revert InvalidSwapDelta();
        uint256 spent = uint256(-int256(inputDelta));
        uint256 received = uint256(uint128(outputDelta));
        if (spent > amount) revert InvalidSwapDelta();
        if (spent == balance) pendingDirection = 0;

        // Pay only the actual filled input; unused input remains available for a future retry.
        poolManager.sync(input);
        uint256 paid;
        if (input.isAddressZero()) {
            paid = poolManager.settle{value: spent}();
        } else {
            input.transfer(address(poolManager), spent);
            paid = poolManager.settle();
        }
        if (paid != spent) revert SettlementMismatch();
        poolManager.take(output, address(this), received);
        emit Rebalanced(strategyPoolId, zeroForOne, spent, received, balance - spent);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        if (address(key.hooks) != address(this)) revert InvalidPool();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_reentrancyGuardEntered()) revert ReentrancyGuardReentrantCall();
        if (params.amountSpecified == 0) revert InvalidAmount();
        if (params.amountSpecified > 0) {
            // In exact-output mode, output is the specified currency. Increase gross pool output
            // and reserve that same increment for the hook, leaving the trader's requested net output.
            uint256 fee = _exactOutputFee(uint256(params.amountSpecified));
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (params.amountSpecified > 0) {
            uint256 netRequested = uint256(params.amountSpecified);
            uint256 expectedGross = netRequested + _exactOutputFee(netRequested);
            if (outputDelta <= 0 || uint256(uint128(outputDelta)) != expectedGross) {
                revert ExactOutputNotFilled();
            }
        }
        // No volume means no observation and no fee. This also covers empty-liquidity price movements.
        if (outputDelta <= 0) return (BaseHook.afterSwap.selector, 0);
        PoolId id = key.toId();
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        uint256 grossOutput = uint256(uint128(outputDelta));
        uint256 fee = grossOutput * FEE_BPS / BPS;
        if (fee != 0) {
            uint256 creatorPart = grossOutput * CREATOR_BPS / BPS;
            uint256 accumulatorPart = fee - creatorPart;
            creatorFees[output] += creatorPart;
            accumulatorFees[output] += accumulatorPart;
            // mint debits this hook; the positive output hook delta credits it by the same fee.
            // That delta comes from afterSwap for exact input, or beforeSwap for exact output.
            poolManager.mint(address(this), output.toId(), fee);
            emit FeeAccrued(id, output, creatorPart, accumulatorPart);
        }

        (uint160 price,,,) = poolManager.getSlot0(id);
        SwapSMA.History storage history = _histories[id];
        int8 cross = history.push(price);
        emit PriceObserved(id, history.observations, price);
        if (cross != 0) {
            (uint160 shortAverage, uint160 longAverage) = history.averages();
            emit CrossDetected(id, cross, shortAverage, longAverage);
        }
        if (strategyConfigured && PoolId.unwrap(id) == PoolId.unwrap(strategyPoolId)) {
            if (cross != 0) pendingDirection = cross;
            if (pendingDirection != 0) {
                try this.executeRebalance() {}
                catch (bytes memory reason) {
                    emit RebalanceDeferred(id, pendingDirection, keccak256(reason));
                }
            }
        }
        // The afterSwap return always applies to the unspecified currency, so exact-output mode
        // must return zero here: its output fee was already reserved as a beforeSwap specified delta.
        return (BaseHook.afterSwap.selector, params.amountSpecified < 0 ? int128(uint128(fee)) : int128(0));
    }

    function _exactOutputFee(uint256 netRequested) private pure returns (uint256 fee) {
        uint256 maxDelta = uint256(uint128(type(int128).max));
        if (netRequested > maxDelta) revert AmountTooLarge();
        fee = netRequested * FEE_BPS / (BPS - FEE_BPS);
        if (netRequested + fee > maxDelta) revert AmountTooLarge();
        // With fee=floor(net/399), gross=net+fee satisfies floor(gross/400)==fee exactly.
    }

    function _validateLimits(uint160 sell0Limit, uint160 sell1Limit, uint160 price) private pure {
        if (
            sell0Limit <= TickMath.MIN_SQRT_PRICE || sell1Limit >= TickMath.MAX_SQRT_PRICE
                || sell0Limit >= price || sell1Limit <= price
        ) revert InvalidPriceLimits();
    }

    function _unlock(bytes memory data) private {
        _unlockCommitment = keccak256(data);
        poolManager.unlock(data);
        if (_unlockCommitment != bytes32(0)) revert UnexpectedCallback();
    }

    /// @notice Native ETH sent here is strategy capital; no shares or depositor claims are issued.
    receive() external payable {}
}
