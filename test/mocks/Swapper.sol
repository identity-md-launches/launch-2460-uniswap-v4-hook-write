// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Prefunded test router. Not a deployed application or a production router.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (BalanceDelta) {
        return swapWithParams(
            key,
            SwapParams(
                zeroForOne,
                -int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
    }

    function swapWithParams(PoolKey memory key, SwapParams memory params) public returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params))), (BalanceDelta));
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        external
        returns (BalanceDelta)
    {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(lower, upper, liquidity, bytes32(0));
        return abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "test: only manager");
        (bool swapping, PoolKey memory key, bytes memory encodedParams) =
            abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (swapping) {
            delta = manager.swap(key, abi.decode(encodedParams, (SwapParams)), "");
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(encodedParams, (ModifyLiquidityParams)), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                currency.transfer(address(manager), amount);
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }

    receive() external payable {}
}
