// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GoldenCrossHook} from "../src/GoldenCrossHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Swapper} from "./mocks/Swapper.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant Q96 = 1 << 96;
    PoolManager internal manager;
    GoldenCrossHook internal hook;
    Swapper internal router;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;
    address internal treasury;
    address internal creator;
    address internal accumulator;
    address internal gasWallet;

    function setUp() public virtual {
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        accumulator = makeAddr("accumulator");
        gasWallet = makeAddr("gas wallet");
        manager = new PoolManager(address(this));
        router = new Swapper(manager);
        hook = _deployHook(creator, accumulator);
        MockERC20 a = new MockERC20("A", "A", 0);
        MockERC20 b = new MockERC20("B", "B", 0);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(router), 1e34);
        token1.mint(address(router), 1e34);
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, hook);
        manager.initialize(key, Q96);
        router.modify(key, -60000, 60000, 1e24);
    }

    function _deployHook(address creator_, address accumulator_) internal returns (GoldenCrossHook result) {
        address target = address(uint160(0x1000000) | HookFlags.GOLDEN_CROSS);
        bytes memory creation = abi.encodePacked(
            type(GoldenCrossHook).creationCode,
            abi.encode(manager, gasWallet, accumulator_, treasury, creator_)
        );
        // Run the real constructor at a flag-valid address, including permission validation.
        vm.etch(target, creation);
        (bool ok, bytes memory runtime) = target.call("");
        require(ok, "test: hook constructor failed");
        vm.etch(target, runtime);
        result = GoldenCrossHook(payable(target));
    }

    function _configure() internal {
        vm.prank(treasury);
        hook.configureStrategy(key, Q96 / 2, Q96 * 2);
    }

    function _price() internal view returns (uint160 price) {
        (price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    /// @dev Real swaps move to chosen prices. Every observation is from actual PoolManager state.
    function _tradeTo(uint160 target) internal returns (BalanceDelta) {
        uint160 price = _price();
        require(target != price, "test: target equals price");
        return router.swapWithParams(key, SwapParams(target < price, -int256(1e28), target));
    }

    function _warmupFlat() internal {
        // Equal alternating samples give sum50/50 == sum200/200 at the 200th sample.
        for (uint256 i; i < 200; ++i) {
            _tradeTo(i % 2 == 0 ? Q96 - 1e15 : Q96);
        }
        (,, uint16 count, uint64 observations, int8 relation) = hook.movingAverages(key.toId());
        assertEq(count, 200);
        assertEq(observations, 200);
        assertEq(relation, 0);
    }

    function _assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0, "hook token0 debt");
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0, "hook token1 debt");
        assertEq(pm.currencyDelta(address(router), key.currency0), 0, "router token0 debt");
        assertEq(pm.currencyDelta(address(router), key.currency1), 0, "router token1 debt");
        assertEq(pm.getNonzeroDeltaCount(), 0, "unsettled manager accounting");
        assertFalse(pm.isUnlocked());
    }
}
