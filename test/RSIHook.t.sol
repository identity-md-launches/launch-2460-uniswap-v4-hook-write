// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RSIFixture} from "./RSIFixture.sol";
import {RSIHook} from "../src/RSIHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {MineRSIHook} from "../script/MineRSIHook.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Vm} from "forge-std/Vm.sol";

contract RSIHookTest is RSIFixture {
    using StateLibrary for IPoolManager;

    function testFuzz_firstFullRSITradesAtFifteenthObservation(bool rising) public {
        _configure();
        token0.mint(address(hook), 1e18);
        token1.mint(address(hook), 1e18);
        for (uint160 i = 1; i <= 14; ++i) {
            _tradeTo(rising ? Q96 + i * 1e18 : Q96 - i * 1e18);
            assertEq(token0.balanceOf(address(hook)), 1e18);
            assertEq(token1.balanceOf(address(hook)), 1e18);
            assertEq(hook.pendingDirection(), 0);
        }
        uint160 lastObservation = rising ? Q96 + 15e18 : Q96 - 15e18;
        _tradeTo(lastObservation);
        (uint256 value, uint8 changes, uint64 observations, int8 direction) = hook.rsi(key.toId());
        assertEq(value, rising ? 10000 : 0);
        assertEq(changes, 14);
        assertEq(observations, 15);
        assertEq(direction, rising ? int8(-1) : int8(1));
        if (rising) {
            assertEq(token0.balanceOf(address(hook)), 0);
            assertGt(token1.balanceOf(address(hook)), 1e18);
            assertLt(_price(), lastObservation, "overbought trade moves lower");
        } else {
            assertEq(token1.balanceOf(address(hook)), 0);
            assertGt(token0.balanceOf(address(hook)), 1e18);
            assertGt(_price(), lastObservation, "oversold trade moves upper");
        }
        _assertSettled();
    }

    function test_neutralObservationCancelsUnfilledPendingRebalance() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        token1.setBlockedSender(address(hook));
        _tradeTo(Q96 - 1e20);
        assertEq(hook.pendingDirection(), 1);
        token1.setBlockedSender(address(0));
        _tradeTo(Q96);
        (uint256 value,,, int8 direction) = hook.rsi(key.toId());
        assertGt(value, 3000);
        assertLt(value, 7000);
        assertEq(direction, 0);
        assertEq(hook.pendingDirection(), 0);
        assertEq(token1.balanceOf(address(hook)), 1e18, "neutral RSI must not retry an old signal");
        assertEq(token0.balanceOf(address(hook)), 0);
        vm.expectRevert(RSIHook.NoPendingRebalance.selector);
        hook.retryRebalance();
        _assertSettled();
    }

    function test_unconfiguredPoolRecordsRSIButCannotSpendInventory() public {
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        _tradeTo(Q96 - 1e20);
        (uint256 value,,, int8 direction) = hook.rsi(key.toId());
        assertLt(value, 3000);
        assertEq(direction, 1);
        assertEq(token1.balanceOf(address(hook)), 1e18);
        assertEq(hook.pendingDirection(), 0);
        _configure();
        // Selecting a pool is not a synthetic observation or a trade.
        assertEq(token1.balanceOf(address(hook)), 1e18);
        _tradeTo(Q96 - 2e20);
        assertEq(token1.balanceOf(address(hook)), 0);
        _assertSettled();
    }

    function test_otherPoolsCannotCancelAPendingStrategyCondition() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        token1.setBlockedSender(address(hook));
        _tradeTo(Q96 - 1e20);
        assertEq(hook.pendingDirection(), 1);
        PoolKey memory selected = key;
        key.fee = 500;
        manager.initialize(key, Q96);
        router.modify(key, -60000, 60000, 1e24);
        _warmupNeutral();
        assertEq(hook.pendingDirection(), 1, "other pool's neutral RSI does not cancel the strategy");
        token1.setBlockedSender(address(0));
        hook.retryRebalance();
        assertEq(token1.balanceOf(address(hook)), 0);
        assertGt(token0.balanceOf(address(hook)), 0);
        assertEq(_price(), Q96 - 1e15, "retry only uses the configured pool");
        key = selected;
        _assertSettled();
    }

    function test_strategyTokenCallbackCannotReenterAnotherSwap() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        token1.setTransferCallback(address(router), abi.encodeCall(router.swap, (key, false, 1e18)));
        _tradeTo(Q96 - 1e20);
        assertTrue(token1.callbackAttempted());
        assertFalse(token1.callbackSucceeded());
        assertEq(token1.balanceOf(address(hook)), 0);
        (,, uint64 observations,) = hook.rsi(key.toId());
        assertEq(observations, 16);
        _assertSettled();
    }

    function test_deploysWithRealCreate2AndPermissionBits() public {
        bytes memory args = abi.encode(manager, gasWallet, accumulator, treasury, creator, charity);
        (address expected, bytes32 salt, bytes32 initCodeHash) =
            new MineRSIHook().run(address(this), manager, gasWallet, accumulator, treasury, creator, charity);
        assertEq(initCodeHash, keccak256(abi.encodePacked(type(RSIHook).creationCode, args)));
        RSIHook mined = new RSIHook{salt: salt}(manager, gasWallet, accumulator, treasury, creator, charity);
        assertEq(address(mined), expected);
        assertTrue(HookFlags.matches(expected, uint160(0x20cc)));
        Hooks.validateHookPermissions(mined, mined.getHookPermissions());
        assertEq(mined.treasury(), treasury);
        assertEq(mined.gasWallet(), gasWallet);
        assertEq(mined.accumulator(), accumulator);
        assertEq(mined.creatorWallet(), creator);
        assertEq(mined.charityRouter(), charity);
        assertLt(address(mined).code.length, 24576);
    }

    function test_constructorRejectsEachZeroArgument() public {
        address target = address(uint160(0x2000000) | uint160(0x20cc));
        address[6] memory args = [address(manager), gasWallet, accumulator, treasury, creator, charity];
        for (uint256 i; i < 6; ++i) {
            address saved = args[i];
            args[i] = address(0);
            vm.etch(target, abi.encodePacked(type(RSIHook).creationCode, abi.encode(args)));
            (bool ok, bytes memory reason) = target.call("");
            assertFalse(ok);
            assertEq(bytes4(reason), RSIHook.ZeroAddress.selector);
            args[i] = saved;
        }
    }

    function test_constructorRejectsBadAddressFlags() public {
        vm.expectRevert();
        new RSIHook(manager, gasWallet, accumulator, treasury, creator, charity);
    }

    function test_constructorRejectsCharityAsHookOrManager() public {
        address target = address(uint160(0x2000000) | uint160(0x20cc));
        for (uint256 i; i < 2; ++i) {
            address recipient = i == 0 ? target : address(manager);
            vm.etch(
                target,
                abi.encodePacked(
                    type(RSIHook).creationCode,
                    abi.encode(manager, gasWallet, accumulator, treasury, creator, recipient)
                )
            );
            (bool ok, bytes memory reason) = target.call("");
            assertFalse(ok);
            assertEq(bytes4(reason), RSIHook.InvalidRecipient.selector);
        }
    }

    function test_charityRedemptionRejectsEmptyAndCannotRepeat() public {
        vm.expectRevert(RSIHook.NothingToRedeem.selector);
        hook.redeemCharityFees(key.currency1);
        router.swap(key, true, 1e20);
        uint256 amount = hook.charityFees(key.currency1);
        assertGt(amount, 0);
        vm.prank(makeAddr("charity keeper"));
        hook.redeemCharityFees(key.currency1);
        assertEq(token1.balanceOf(charity), amount);
        assertEq(hook.charityFees(key.currency1), 0);
        vm.expectRevert(RSIHook.NothingToRedeem.selector);
        hook.redeemCharityFees(key.currency1);
        _assertSettled();
    }

    function test_charityTransferFailureAndReentryPreserveAccounting() public {
        router.swap(key, true, 1e20);
        uint256 amount = hook.charityFees(key.currency1);
        uint256 claims = manager.balanceOf(address(hook), key.currency1.toId());
        token1.setRejectTransfers(true);
        vm.expectRevert();
        hook.redeemCharityFees(key.currency1);
        assertEq(hook.charityFees(key.currency1), amount);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), claims);
        token1.setRejectTransfers(false);
        token1.setTransferCallback(address(hook), abi.encodeCall(hook.redeemCharityFees, (key.currency1)));
        hook.redeemCharityFees(key.currency1);
        assertTrue(token1.callbackAttempted());
        assertFalse(token1.callbackSucceeded());
        assertEq(token1.balanceOf(charity), amount);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), claims - amount);
        _assertSettled();
    }

    function testFuzz_smallExactOutputsRoundAndConserveAllThreeFees(uint16 raw, bool zeroForOne) public {
        uint256 requested = bound(raw, 1, 10000);
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        BalanceDelta net = router.swapWithParams(
            key, SwapParams(zeroForOne, int256(requested), zeroForOne ? Q96 / 2 : Q96 * 2)
        );
        assertEq(uint256(uint128(zeroForOne ? net.amount1() : net.amount0())), requested);
        uint256 fee = manager.balanceOf(address(hook), output.toId());
        uint256 gross = requested + fee;
        assertEq(fee, gross * 45 / 10000);
        assertEq(hook.creatorFees(output), gross * 17 / 10000);
        assertEq(hook.charityFees(output), gross * 3 / 10000);
        assertEq(hook.accumulatorFees(output), fee - gross * 17 / 10000 - gross * 3 / 10000);
        assertGe(hook.accumulatorFees(output), gross * 25 / 10000);
        assertLe(hook.accumulatorFees(output), gross * 25 / 10000 + 2);
        _assertSettled();
    }

    function test_runtimeHasNoEscapeOpcodes() public view {
        bytes memory code = address(hook).code;
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }

    function test_callbacksAndUnlockRefuseImpersonation() public {
        vm.expectRevert();
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert();
        hook.beforeSwap(address(this), key, SwapParams(true, -1e18, Q96 / 2), "");
        vm.expectRevert();
        hook.afterSwap(address(this), key, SwapParams(true, -1e18, Q96 / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert();
        hook.unlockCallback(abi.encode(uint8(2), key.currency0));
        vm.prank(address(manager));
        vm.expectRevert(RSIHook.UnexpectedCallback.selector);
        hook.unlockCallback(abi.encode(uint8(2), key.currency0));
        vm.expectRevert(RSIHook.OnlySelf.selector);
        hook.executeRebalance();
    }

    function test_unsetConfigurationFailsClearlyAndTreasuryControlsIt() public {
        vm.expectRevert(RSIHook.StrategyNotConfigured.selector);
        hook.strategyKey();
        vm.expectRevert(RSIHook.StrategyNotConfigured.selector);
        hook.retryRebalance();
        vm.prank(treasury);
        vm.expectRevert(RSIHook.StrategyNotConfigured.selector);
        hook.setPriceLimits(Q96 / 2, Q96 * 2);
        vm.expectRevert(RSIHook.OnlyTreasury.selector);
        hook.configureStrategy(key, Q96 / 2, Q96 * 2);
        _configure();
        assertTrue(hook.strategyConfigured());
        assertEq(abi.encode(hook.strategyKey()), abi.encode(key));
        vm.prank(treasury);
        vm.expectRevert(RSIHook.StrategyAlreadyConfigured.selector);
        hook.configureStrategy(key, Q96 / 2, Q96 * 2);
        vm.expectRevert(RSIHook.OnlyTreasury.selector);
        hook.setPriceLimits(Q96 / 2, Q96 * 2);
        vm.expectRevert(RSIHook.NoPendingRebalance.selector);
        hook.retryRebalance();
    }

    function test_configurationRejectsWrongPoolUninitializedAndInvalidLimits() public {
        PoolKey memory badKey = key;
        badKey.hooks = IHooks(address(this));
        vm.startPrank(treasury);
        vm.expectRevert(RSIHook.InvalidPool.selector);
        hook.configureStrategy(badKey, Q96 / 2, Q96 * 2);
        badKey = key;
        badKey.fee = 500;
        vm.expectRevert(RSIHook.PoolNotInitialized.selector);
        hook.configureStrategy(badKey, Q96 / 2, Q96 * 2);
        vm.expectRevert(RSIHook.InvalidPriceLimits.selector);
        hook.configureStrategy(key, Q96, Q96 * 2);
        vm.expectRevert(RSIHook.InvalidPriceLimits.selector);
        hook.configureStrategy(key, Q96 / 2, Q96);
        vm.expectRevert(RSIHook.InvalidPriceLimits.selector);
        hook.configureStrategy(key, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1);
        vm.stopPrank();
    }

    function test_exactOutputPartialFillRevertsWithoutStateChange() public {
        uint160 beforePrice = _price();
        for (uint256 i; i < 2; ++i) {
            vm.expectRevert();
            router.swapWithParams(key, SwapParams(i == 0, 1e22, i == 0 ? Q96 - 1e15 : Q96 + 1e15));
        }
        assertEq(_price(), beforePrice);
        (,, uint64 observations,) = hook.rsi(key.toId());
        assertEq(observations, 0);
        _assertSettled();
    }

    function testFuzz_exactOutputKeepsRequestedNetAndChargesOnlyOutput(bool zeroForOne, uint96 output)
        public
    {
        uint256 requested = bound(output, 1, 1e21);
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        BalanceDelta delta = router.swapWithParams(
            key, SwapParams(zeroForOne, int256(requested), zeroForOne ? Q96 / 2 : Q96 * 2)
        );
        assertEq(uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0())), requested);
        uint256 creatorPart = hook.creatorFees(outputCurrency);
        uint256 accumulatorPart = hook.accumulatorFees(outputCurrency);
        uint256 charityPart = hook.charityFees(outputCurrency);
        uint256 fee = creatorPart + accumulatorPart + charityPart;
        assertEq(fee, (requested + fee) * 45 / 10000);
        assertEq(creatorPart, (requested + fee) * 17 / 10000);
        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        assertEq(hook.creatorFees(inputCurrency), 0);
        assertEq(hook.accumulatorFees(inputCurrency), 0);
        assertEq(manager.balanceOf(address(hook), outputCurrency.toId()), fee);
        _assertSettled();
    }

    function test_exactOutputFeeReservationCannotOverflowSignedDelta() public {
        vm.prank(address(manager));
        vm.expectRevert(RSIHook.AmountTooLarge.selector);
        hook.beforeSwap(address(router), key, SwapParams(true, type(int128).max, Q96 / 2), "");
        vm.prank(address(manager));
        vm.expectRevert(RSIHook.AmountTooLarge.selector);
        hook.beforeSwap(address(router), key, SwapParams(false, type(int256).max, Q96 * 2), "");
    }

    function test_exactOutputCanTriggerRebalanceWithoutChangingNetOutput() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        BalanceDelta delta = router.swapWithParams(key, SwapParams(true, 1e20, Q96 / 2));
        assertEq(delta.amount1(), 1e20);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertGt(token0.balanceOf(address(hook)), 0);
        (,, uint64 observations,) = hook.rsi(key.toId());
        assertEq(observations, 16);
        _assertSettled();
    }

    function testFuzz_feeIsExactly45BpsOfGrossOutput(bool zeroForOne, uint96 input) public {
        uint256 amount = bound(input, 1e6, 1e22);
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 managerBefore = output.balanceOf(address(manager));
        BalanceDelta net = router.swap(key, zeroForOne, amount);
        uint256 netOutput = uint256(uint128(zeroForOne ? net.amount1() : net.amount0()));
        uint256 creatorPart = hook.creatorFees(output);
        uint256 accumulatorPart = hook.accumulatorFees(output);
        uint256 charityPart = hook.charityFees(output);
        uint256 fee = creatorPart + accumulatorPart + charityPart;
        uint256 gross = netOutput + fee;
        assertEq(fee, gross * 45 / 10000);
        assertEq(creatorPart, gross * 17 / 10000);
        assertEq(charityPart, gross * 3 / 10000);
        assertEq(accumulatorPart, fee - creatorPart - charityPart);
        assertEq(managerBefore - output.balanceOf(address(manager)), netOutput);
        assertEq(manager.balanceOf(address(hook), output.toId()), fee);
        assertEq(output.balanceOf(address(hook)), 0, "claims are not strategy inventory");
        _assertSettled();
    }

    function test_redeemFeesPaysOnlyFixedRecipientsAndCannotRepeat() public {
        router.swap(key, true, 1e20);
        uint256 creatorPart = hook.creatorFees(key.currency1);
        uint256 accumulatorPart = hook.accumulatorFees(key.currency1);
        assertGt(creatorPart, 0);
        assertGt(accumulatorPart, 0);
        vm.prank(makeAddr("permissionless caller"));
        hook.redeemFees(key.currency1, true);
        uint256 charityPart = hook.charityFees(key.currency1);
        hook.redeemFees(key.currency1, false);
        hook.redeemCharityFees(key.currency1);
        assertEq(token1.balanceOf(charity), charityPart);
        assertEq(hook.charityFees(key.currency1), 0);
        assertEq(token1.balanceOf(creator), creatorPart);
        assertEq(token1.balanceOf(accumulator), accumulatorPart);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(hook.creatorFees(key.currency1), 0);
        assertEq(hook.accumulatorFees(key.currency1), 0);
        vm.expectRevert(RSIHook.NothingToRedeem.selector);
        hook.redeemFees(key.currency1, true);
        _assertSettled();
    }

    function test_feeRedemptionFailurePreservesClaimsAndOtherRecipientCanRedeem() public {
        router.swap(key, true, 1e20);
        uint256 claim = hook.creatorFees(key.currency1);
        uint256 allClaims = manager.balanceOf(address(hook), key.currency1.toId());
        token1.setRejectTransfers(true);
        vm.expectRevert();
        hook.redeemFees(key.currency1, true);
        assertEq(hook.creatorFees(key.currency1), claim);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), allClaims);
        token1.setRejectTransfers(false);
        hook.redeemFees(key.currency1, false);
        hook.redeemFees(key.currency1, true);
        _assertSettled();
    }

    function test_oversoldSellsEntireToken1AndNoRecursiveObservationOrFee() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        vm.recordLogs();
        _tradeTo(Q96 - 1e20);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertGt(token0.balanceOf(address(hook)), 0);
        assertEq(hook.pendingDirection(), 0);
        (,, uint64 observations, int8 relation) = hook.rsi(key.toId());
        assertEq(observations, 16);
        assertEq(relation, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeEvents;
        uint256 tradeEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == keccak256("FeeAccrued(bytes32,address,uint256,uint256,uint256)")) {
                ++feeEvents;
            }
            if (logs[i].topics[0] == keccak256("Rebalanced(bytes32,bool,uint256,uint256,uint256)")) {
                ++tradeEvents;
            }
        }
        assertEq(feeEvents, 1);
        assertEq(tradeEvents, 1);
        _assertSettled();
    }

    function test_overboughtSellsEntireToken0() public {
        _configure();
        _warmupNeutral();
        token0.mint(address(hook), 1e18);
        _tradeTo(Q96 + 1e20);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertGt(token1.balanceOf(address(hook)), 0);
        assertEq(hook.pendingDirection(), 0);
        (,, uint64 observations, int8 relation) = hook.rsi(key.toId());
        assertEq(observations, 16);
        assertEq(relation, -1);
        _assertSettled();
    }

    function test_warmupDoesNotTradeAndPersistentOversoldTradesNewFunding() public {
        _configure();
        token1.mint(address(hook), 1e18);
        _warmupNeutral();
        assertEq(token1.balanceOf(address(hook)), 1e18);
        _tradeTo(Q96 - 1e20);
        token1.mint(address(hook), 1e18);
        _tradeTo(Q96 - 2e20);
        assertEq(token1.balanceOf(address(hook)), 0, "RSI condition is tested on every sample");
        _assertSettled();
    }

    function test_emptyInventoryClearsPendingButNextOversoldSampleCanTrade() public {
        _configure();
        _warmupNeutral();
        _tradeTo(Q96 - 1e20);
        assertEq(hook.pendingDirection(), 0);
        token1.mint(address(hook), 1e18);
        _tradeTo(Q96 - 2e20);
        assertEq(token1.balanceOf(address(hook)), 0);
        _assertSettled();
    }

    function test_partialFillRetainsInputAndRetryCompletesIt() public {
        _configure();
        _warmupNeutral();
        vm.prank(treasury);
        hook.setPriceLimits(Q96 / 2, Q96 + 2e20);
        token1.mint(address(hook), 1e22);
        _tradeTo(Q96 - 1e20);
        uint256 remaining = token1.balanceOf(address(hook));
        assertGt(remaining, 0);
        assertLt(remaining, 1e22);
        assertEq(_price(), Q96 + 2e20);
        assertEq(hook.pendingDirection(), 1);
        _assertSettled();
        vm.expectRevert(RSIHook.PriceLimitReached.selector);
        hook.retryRebalance();
        vm.prank(treasury);
        hook.setPriceLimits(Q96 / 2, Q96 * 2);
        hook.retryRebalance();
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(hook.pendingDirection(), 0);
        (,, uint64 observations,) = hook.rsi(key.toId());
        assertEq(observations, 16, "retry does not create an observation");
        _assertSettled();
    }

    function test_failedAutomaticTransferRollsBackRebalanceButKeepsUserTradeAndSignal() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        token1.setBlockedSender(address(hook));
        _tradeTo(Q96 - 1e20);
        assertEq(token1.balanceOf(address(hook)), 1e18);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(hook.pendingDirection(), 1);
        assertEq(_price(), Q96 - 1e20, "inner swap must roll back too");
        _assertSettled();
        token1.setBlockedSender(address(0));
        hook.retryRebalance();
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(hook.pendingDirection(), 0);
        _assertSettled();
    }

    function test_pendingSignalRetriesOnNextSwapAndOppositeConditionSupersedesIt() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        token1.setBlockedSender(address(hook));
        _tradeTo(Q96 - 1e20);
        assertEq(hook.pendingDirection(), 1);
        token1.setBlockedSender(address(0));
        _tradeTo(Q96 - 2e20);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertEq(hook.pendingDirection(), 0);
        _tradeTo(Q96 + 1e22);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertGt(token1.balanceOf(address(hook)), 0);
        _assertSettled();
    }

    function test_otherPoolHasIsolatedHistoryAndCannotSpendStrategyCapital() public {
        _configure();
        PoolKey memory original = key;
        key.fee = 12500;
        manager.initialize(key, Q96);
        router.modify(key, -60000, 60000, 1e24);
        token1.mint(address(hook), 1e18);
        _warmupNeutral();
        _tradeTo(Q96 - 1e20);
        assertEq(token1.balanceOf(address(hook)), 1e18);
        (,, uint64 firstCount,) = hook.rsi(original.toId());
        (,, uint64 otherCount,) = hook.rsi(key.toId());
        assertEq(firstCount, 0);
        assertEq(otherCount, 16);
        assertEq(hook.pendingDirection(), 0);
        _assertSettled();
    }

    function test_treasuryWithdrawsOnlyToAccumulatorAndCannotTouchClaims() public {
        router.swap(key, true, 1e20);
        uint256 creatorPart = hook.creatorFees(key.currency1);
        token1.mint(address(hook), 1e18);
        vm.expectRevert(RSIHook.OnlyTreasury.selector);
        hook.withdrawStrategy(key.currency1, 1e18);
        vm.prank(treasury);
        hook.withdrawStrategy(key.currency1, 1e18);
        assertEq(token1.balanceOf(accumulator), 1e18);
        assertEq(hook.creatorFees(key.currency1), creatorPart);
        vm.prank(treasury);
        vm.expectRevert(RSIHook.InvalidAmount.selector);
        hook.withdrawStrategy(key.currency1, 1);
        hook.redeemFees(key.currency1, true);
        assertEq(token1.balanceOf(creator), creatorPart);
        _assertSettled();
    }

    function test_lpCanCollectAndRemoveWithoutHookFee() public {
        router.swap(key, true, 1e20);
        uint256 claims = manager.balanceOf(address(hook), key.currency1.toId());
        BalanceDelta collected = router.modify(key, -60000, 60000, 0);
        assertTrue(collected.amount0() >= 0 && collected.amount1() >= 0);
        router.modify(key, -60000, 60000, -int256(1e24));
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), claims);
        _assertSettled();
    }

    function test_tokenCallbackCannotReenterAndCannotStealClaims() public {
        router.swap(key, true, 1e20);
        uint256 creatorPart = hook.creatorFees(key.currency1);
        uint256 accumulatorPart = hook.accumulatorFees(key.currency1);
        token1.setTransferCallback(address(hook), abi.encodeCall(hook.redeemFees, (key.currency1, false)));
        hook.redeemFees(key.currency1, true);
        assertTrue(token1.callbackAttempted());
        assertFalse(token1.callbackSucceeded());
        assertEq(token1.balanceOf(creator), creatorPart);
        assertEq(hook.accumulatorFees(key.currency1), accumulatorPart);
        _assertSettled();
    }

    function test_noLiquiditySwapDoesNotPolluteHistory() public {
        router.modify(key, -60000, 60000, -int256(1e24));
        BalanceDelta result = _tradeTo(Q96 / 2);
        assertEq(BalanceDelta.unwrap(result), 0);
        (,, uint64 observations,) = hook.rsi(key.toId());
        assertEq(observations, 0);
        assertEq(hook.creatorFees(key.currency0), 0);
        assertEq(hook.creatorFees(key.currency1), 0);
        _assertSettled();
    }

    function test_oppositeConditionReplacesUnfilledPendingDirection() public {
        _configure();
        _warmupNeutral();
        token0.mint(address(hook), 1e18);
        token1.mint(address(hook), 1e18);
        token1.setBlockedSender(address(hook));
        _tradeTo(Q96 - 1e20);
        assertEq(hook.pendingDirection(), 1);
        _tradeTo(Q96 + 1e22);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertGt(token1.balanceOf(address(hook)), 1e18);
        assertEq(hook.pendingDirection(), 0);
        _assertSettled();
    }

    function test_pendingRetryWithNoLiquidityRevertsAndPreservesInventory() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        token1.setBlockedSender(address(hook));
        _tradeTo(Q96 - 1e20);
        token1.setBlockedSender(address(0));
        router.modify(key, -60000, 60000, -int256(1e24));
        uint160 beforePrice = _price();
        vm.expectRevert(RSIHook.NoFill.selector);
        hook.retryRebalance();
        assertEq(token1.balanceOf(address(hook)), 1e18);
        assertEq(_price(), beforePrice);
        assertEq(hook.pendingDirection(), 1);
        _assertSettled();
    }

    function test_feeOnTransferStrategyInputFailsAtomically() public {
        _configure();
        _warmupNeutral();
        token1.mint(address(hook), 1e18);
        uint256 supply = token1.totalSupply();
        token1.setTaxedSender(address(hook));
        _tradeTo(Q96 - 1e20);
        assertEq(token1.balanceOf(address(hook)), 1e18);
        assertEq(token1.totalSupply(), supply);
        assertEq(hook.pendingDirection(), 1);
        vm.expectRevert(RSIHook.SettlementMismatch.selector);
        hook.retryRebalance();
        token1.setTaxedSender(address(0));
        hook.retryRebalance();
        assertEq(hook.pendingDirection(), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        _assertSettled();
    }

    function test_saltMinerRequiresExplicitDeploymentInputs() public {
        MineRSIHook miner = new MineRSIHook();
        vm.expectRevert("Missing CREATE2 deployer");
        miner.run(address(0), manager, gasWallet, accumulator, treasury, creator, charity);
        vm.expectRevert("Missing constructor parameter");
        miner.run(address(this), manager, gasWallet, accumulator, treasury, address(0), charity);
    }
}
