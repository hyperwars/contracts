// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGameRoom} from "../../src/interfaces/IGameRoom.sol";

/// @notice Minimal mock GameRoom for PlayerProxy tests.
contract MockGameRoom is IGameRoom {
    bool public shouldReject;

    function setReject(bool _reject) external {
        shouldReject = _reject;
    }

    function validateTrade(address, uint32) external view override returns (bool) {
        return !shouldReject;
    }

    function join() external override {}
    function claimRefund() external override {}
    function startRound() external override {}
    function activateAgent(address) external override {}
    function cancel() external override {}
    function slice(uint32[] calldata) external override {}
    function settleByTimeLimit() external override {}
    function advanceSettlement() external override {}
    function checkpoint() external override {}

    function getPlayerScore(address) external pure override returns (int256) {
        return 0;
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
