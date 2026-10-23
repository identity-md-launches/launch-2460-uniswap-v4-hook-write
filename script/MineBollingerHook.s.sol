// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {BollingerHook} from "../src/BollingerHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Read-only salt calculation. Does not broadcast, deploy a pool, or load a key/environment.
contract MineBollingerHook {
    function run(
        address create2Deployer,
        IPoolManager manager,
        address gasWallet,
        address accumulator,
        address governanceTreasury,
        address creatorWallet,
        address charityRouter
    ) external view returns (address predicted, bytes32 salt, bytes32 initCodeHash) {
        require(create2Deployer != address(0), "Missing CREATE2 deployer");
        require(
            address(manager) != address(0) && gasWallet != address(0) && accumulator != address(0)
                && governanceTreasury != address(0) && creatorWallet != address(0)
                && charityRouter != address(0),
            "Missing constructor parameter"
        );
        bytes memory args =
            abi.encode(manager, gasWallet, accumulator, governanceTreasury, creatorWallet, charityRouter);
        (predicted, salt) =
            HookMiner.find(create2Deployer, HookFlags.GOLDEN_CROSS, type(BollingerHook).creationCode, args);
        initCodeHash = keccak256(abi.encodePacked(type(BollingerHook).creationCode, args));
    }
}
