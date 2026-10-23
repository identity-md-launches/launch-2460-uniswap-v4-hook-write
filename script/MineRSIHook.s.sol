// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {RSIHook} from "../src/RSIHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Read-only salt calculation. Does not broadcast, deploy a pool, or load a key/environment.
contract MineRSIHook {
    function run(
        address create2Deployer,
        IPoolManager manager,
        address gasWallet,
        address accumulator,
        address treasury,
        address creatorWallet,
        address charityRouter
    ) external view returns (address predicted, bytes32 salt, bytes32 initCodeHash) {
        require(create2Deployer != address(0), "Missing CREATE2 deployer");
        require(
            address(manager) != address(0) && gasWallet != address(0) && accumulator != address(0)
                && treasury != address(0) && creatorWallet != address(0) && charityRouter != address(0),
            "Missing constructor parameter"
        );
        bytes memory args =
            abi.encode(manager, gasWallet, accumulator, treasury, creatorWallet, charityRouter);
        (predicted, salt) = HookMiner.find(
            create2Deployer,
            (Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG),
            type(RSIHook).creationCode,
            args
        );
        initCodeHash = keccak256(abi.encodePacked(type(RSIHook).creationCode, args));
    }
}
