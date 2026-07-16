// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGameRoom} from "../../src/interfaces/IGameRoom.sol";

/// @notice Minimal mock GameRoom for PlayerProxy tests.
contract MockGameRoom is IGameRoom {
    bool public shouldReject;
    bool public withdrawAllowed = true;

    function setReject(bool _reject) external {
        shouldReject = _reject;
    }

    function setWithdrawAllowed(bool _allowed) external {
        withdrawAllowed = _allowed;
    }

    function validateTrade(address, uint32) external view override returns (bool) {
        return !shouldReject;
    }

    function canWithdraw(address) external view override returns (bool) {
        return withdrawAllowed;
    }

    function register(address) external override {}
    function refund(address) external override {}

    function deployProxy(address) external pure override returns (address) {
        return address(0);
    }

    function startRound() external override {}
    function activatePlayer(address) external override {}
    function authorizeAgent(address, address, uint256, bytes calldata) external override {}
    function cancel() external override {}
    function finish() external override {}
    function checkpointPlayer(address) external override {}

    function getPlayerScore(address) external pure override returns (int256) {
        return 0;
    }

    function predictProxy(address) external pure override returns (address) {
        return address(0);
    }

    function getConfig() external pure override returns (GameConfig memory) {
        GameConfig memory c;
        return c;
    }

    function getPlayers() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function getPlayerCount() external pure override returns (uint256) {
        return 0;
    }
}
