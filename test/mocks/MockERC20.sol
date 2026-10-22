// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test fixture only; not a launch token.
contract MockERC20 is ERC20 {
    bool public rejectTransfers;
    address public blockedSender;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    address public taxedSender;

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRejectTransfers(bool reject) external {
        rejectTransfers = reject;
    }

    function setBlockedSender(address sender) external {
        blockedSender = sender;
    }

    function setTransferCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function setTaxedSender(address sender) external {
        taxedSender = sender;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!rejectTransfers && (from == address(0) || from != blockedSender), "test: transfer blocked");
        if (from != address(0) && from == taxedSender && to != address(0)) {
            uint256 tax = amount / 100;
            super._update(from, to, amount - tax);
            super._update(from, address(0), tax);
        } else {
            super._update(from, to, amount);
        }
        if (callbackTarget != address(0) && from != address(0)) {
            callbackAttempted = true;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
        }
    }
}
