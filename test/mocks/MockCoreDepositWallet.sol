// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";

/// @notice Mock CoreDepositWallet for testing bridgeUsdcToCoreFor.
contract MockCoreDepositWallet {
    function deposit(uint256 amount, uint32) external {
        IERC20(HLConstants.usdc()).transferFrom(msg.sender, address(this), amount);
    }

    function depositFor(address, uint256 amount, uint32) external {
        IERC20(HLConstants.usdc()).transferFrom(msg.sender, address(this), amount);
    }
}
