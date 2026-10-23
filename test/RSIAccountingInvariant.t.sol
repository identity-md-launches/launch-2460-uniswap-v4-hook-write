// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RSIFixture} from "./RSIFixture.sol";
import {RSIHook} from "../src/RSIHook.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RSIAccountingHandler is Test {
    RSIHook private immutable hook;
    Swapper private immutable router;
    PoolKey private key;
    mapping(Currency => uint256) public accrued;
    mapping(Currency => uint256) public redeemed;

    constructor(RSIHook hook_, Swapper router_, PoolKey memory key_) {
        hook = hook_;
        router = router_;
        key = key_;
        accrued[key.currency0] = hook.creatorFees(key.currency0) + hook.accumulatorFees(key.currency0)
            + hook.charityFees(key.currency0);
        accrued[key.currency1] = hook.creatorFees(key.currency1) + hook.accumulatorFees(key.currency1)
            + hook.charityFees(key.currency1);
    }

    function swap(uint96 amount, bool zeroForOne, bool exactOutput) external {
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint256 beforeFee = hook.creatorFees(output) + hook.accumulatorFees(output) + hook.charityFees(output);
        uint256 specified = bound(amount, 1e10, 1e21);
        BalanceDelta net = exactOutput
            ? router.swapWithParams(
                key,
                SwapParams(
                    zeroForOne,
                    int256(specified),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                )
            )
            : router.swap(key, zeroForOne, specified);
        uint256 fee =
            hook.creatorFees(output) + hook.accumulatorFees(output) + hook.charityFees(output) - beforeFee;
        uint256 netOut = uint256(uint128(zeroForOne ? net.amount1() : net.amount0()));
        if (exactOutput) assertEq(netOut, specified);
        assertEq(fee, (netOut + fee) * 45 / 10000);
        accrued[output] += fee;
    }

    function redeem(bool currency0, bool forCreator) external {
        Currency currency = currency0 ? key.currency0 : key.currency1;
        uint256 amount = forCreator ? hook.creatorFees(currency) : hook.accumulatorFees(currency);
        if (amount == 0) return;
        hook.redeemFees(currency, forCreator);
        redeemed[currency] += amount;
    }

    function redeemCharity(bool currency0) external {
        Currency currency = currency0 ? key.currency0 : key.currency1;
        uint256 amount = hook.charityFees(currency);
        if (amount == 0) return;
        hook.redeemCharityFees(currency);
        redeemed[currency] += amount;
    }
}

contract RSIAccountingInvariantTest is RSIFixture {
    RSIAccountingHandler private handler;

    function setUp() public override {
        super.setUp();
        _configure();
        _warmupNeutral();
        token0.mint(address(hook), 1e18);
        token1.mint(address(hook), 1e18);
        handler = new RSIAccountingHandler(hook, router, key);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.redeemCharity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allDeltasAreSettledAndClaimsMatchLiabilities() public view {
        _assertSettled();
        _assertClaims(key.currency0);
        _assertClaims(key.currency1);
    }

    function invariant_tokensAreConservedAcrossAllParticipants() public view {
        assertEq(
            token0.totalSupply(),
            token0.balanceOf(address(router)) + token0.balanceOf(address(manager))
                + token0.balanceOf(address(hook)) + token0.balanceOf(creator) + token0.balanceOf(accumulator)
                + token0.balanceOf(charity)
        );
        assertEq(
            token1.totalSupply(),
            token1.balanceOf(address(router)) + token1.balanceOf(address(manager))
                + token1.balanceOf(address(hook)) + token1.balanceOf(creator) + token1.balanceOf(accumulator)
                + token1.balanceOf(charity)
        );
    }

    function _assertClaims(Currency currency) private view {
        uint256 liability =
            hook.creatorFees(currency) + hook.accumulatorFees(currency) + hook.charityFees(currency);
        assertEq(manager.balanceOf(address(hook), currency.toId()), liability);
        assertEq(handler.accrued(currency) - handler.redeemed(currency), liability);
        assertGe(currency.balanceOf(address(manager)), liability);
    }
}
