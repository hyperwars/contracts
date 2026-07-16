// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GameRoomBase} from "../../src/GameRoomBase.sol";

/// @dev Test harness — lets tests override per-player score without wiring real checkpoints.
contract HarnessGameRoom is GameRoomBase {
    mapping(address => int256) private _forcedScore;
    bool private _scoreForced;

    function forceScore(address player, int256 score) external {
        _forcedScore[player] = score;
        _scoreForced = true;
    }

    function clearForcedScore() external {
        _scoreForced = false;
    }

    function getPlayerScore(address player) public view override returns (int256) {
        if (_scoreForced) return _forcedScore[player];
        return super.getPlayerScore(player);
    }
}
