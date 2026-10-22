// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./HookFixture.sol";
import {GoldenCrossHook} from "../src/GoldenCrossHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract FeeReceiver {
    bool public rejecting;
    bool public attempted;
    bool public reentered;
    address public target;
    bytes public payload;

    function configure(bool reject, address target_, bytes calldata payload_) external {
        rejecting = reject;
        target = target_;
        payload = payload_;
    }

    receive() external payable {
        require(!rejecting, "test: reject ETH");
        if (target != address(0)) {
            attempted = true;
            (reentered,) = target.call(payload);
        }
    }
}

contract NativeHookTest is HookFixture {
    FeeReceiver internal receiver;

    function setUp() public override {
        treasury = makeAddr("treasury");
        accumulator = makeAddr("accumulator");
        gasWallet = makeAddr("gas wallet");
        receiver = new FeeReceiver();
        creator = address(receiver);
        manager = new PoolManager(address(this));
        router = new Swapper(manager);
        hook = _deployHook(creator, accumulator);
        token1 = new MockERC20("Token", "TKN", 0);
        token1.mint(address(router), 1e34);
        vm.deal(address(router), 1e34);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token1)), 12500, 60, hook);
        manager.initialize(key, Q96);
    }

    function test_freshManagerTokenOnlySeedCanBuyAndAccrueOutputFees() public {
        router.modify(key, -6000, -60, 1e24);
        assertEq(address(manager).balance, 0);
        BalanceDelta result = router.swap(key, true, 1e18);
        assertLt(result.amount0(), 0);
        assertGt(result.amount1(), 0);
        assertGt(hook.creatorFees(key.currency1), 0);
        assertGt(hook.accumulatorFees(key.currency1), 0);
        assertGt(address(manager).balance, 0);
        hook.redeemFees(key.currency1, true);
        assertGt(token1.balanceOf(creator), 0);
        _assertSettled();
    }

    function test_nativeOutputFeeAndRejectingRecipientDoNotBlockSwaps() public {
        router.modify(key, -60000, 60000, 1e24);
        receiver.configure(true, address(0), "");
        uint256 beforeNative = address(router).balance;
        BalanceDelta result = router.swap(key, false, 1e20);
        uint256 net = uint256(uint128(result.amount0()));
        uint256 creatorPart = hook.creatorFees(key.currency0);
        uint256 accumulatorPart = hook.accumulatorFees(key.currency0);
        uint256 gross = net + creatorPart + accumulatorPart;
        assertEq(net, address(router).balance - beforeNative);
        assertEq(creatorPart, gross * 20 / 10000);
        assertEq(creatorPart + accumulatorPart, gross * 25 / 10000);
        vm.expectRevert();
        hook.redeemFees(key.currency0, true);
        assertEq(hook.creatorFees(key.currency0), creatorPart);
        hook.redeemFees(key.currency0, false);
        assertEq(accumulator.balance, accumulatorPart);
        router.swap(key, false, 1e20);
        assertGt(hook.creatorFees(key.currency0), creatorPart);
        receiver.configure(false, address(0), "");
        hook.redeemFees(key.currency0, true);
        assertGt(creator.balance, creatorPart);
        _assertSettled();
    }

    function test_nativeRecipientCannotReenterFeeRedemption() public {
        router.modify(key, -60000, 60000, 1e24);
        router.swap(key, false, 1e20);
        uint256 creatorPart = hook.creatorFees(key.currency0);
        receiver.configure(false, address(hook), abi.encodeCall(hook.redeemFees, (key.currency0, true)));
        hook.redeemFees(key.currency0, true);
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(creator.balance, creatorPart);
        assertEq(hook.creatorFees(key.currency0), 0);
        _assertSettled();
    }

    function test_nativeCapitalIsSettledAndRebalanceOutputIsRetained() public {
        router.modify(key, -60000, 60000, 1e24);
        _configure();
        _warmupFlat();
        vm.deal(address(hook), 1e18);
        _tradeTo(Q96 - 1e20);
        assertEq(address(hook).balance, 0);
        assertGt(token1.balanceOf(address(hook)), 0);
        _tradeTo(Q96 + 1e22);
        assertEq(token1.balanceOf(address(hook)), 0);
        assertGt(address(hook).balance, 0);
        _assertSettled();
    }

    function test_nativeExactOutputInBothDirections() public {
        router.modify(key, -60000, 60000, 1e24);
        BalanceDelta buy = router.swapWithParams(key, SwapParams(true, 1e18, Q96 / 2));
        assertEq(buy.amount1(), 1e18);
        assertGt(hook.creatorFees(key.currency1), 0);
        BalanceDelta sell = router.swapWithParams(key, SwapParams(false, 1e18, Q96 * 2));
        assertEq(sell.amount0(), 1e18);
        assertGt(hook.creatorFees(key.currency0), 0);
        hook.redeemFees(key.currency0, true);
        hook.redeemFees(key.currency1, true);
        _assertSettled();
    }
}
