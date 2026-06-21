// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IGameRoom} from "./interfaces/IGameRoom.sol";
import {IGameRoomFactory} from "./interfaces/IGameRoomFactory.sol";
import {GameRoomBase} from "./GameRoomBase.sol";

contract GameRoomFactory is IGameRoomFactory {
    address public immutable roomImplementation;
    address public immutable builderFeeRecipient;
    uint256 public immutable maxPlayers;
    uint256 public immutable maxAssets;
    uint256 public immutable maxRoundDuration;

    error MaxPlayersExceeded();
    error MaxAssetsExceeded();
    error MaxRoundDurationExceeded();

    constructor(
        address roomImpl,
        address builderFeeRecipient_,
        uint256 maxPlayers_,
        uint256 maxAssets_,
        uint256 maxRoundDuration_
    ) {
        roomImplementation = roomImpl;
        builderFeeRecipient = builderFeeRecipient_;
        maxPlayers = maxPlayers_;
        maxAssets = maxAssets_;
        maxRoundDuration = maxRoundDuration_;
    }

    function createRoom(IGameRoom.GameConfig calldata config, address proxyImpl) external returns (address room) {
        if (config.maxPlayers > maxPlayers) revert MaxPlayersExceeded();
        if (config.allowedAssets.length > maxAssets) revert MaxAssetsExceeded();
        if (config.maxRoundDuration > maxRoundDuration) revert MaxRoundDurationExceeded();
        room = Clones.clone(roomImplementation);
        GameRoomBase(room).initialize(config, proxyImpl);
    }

    function tradingBalancePerPlayer(IGameRoom.GameConfig calldata config) external pure returns (uint256) {
        uint256 prizeShare = (config.entryBet * config.prizePoolShare) / 10_000;
        uint256 slicerShare = (config.entryBet * config.slicerIncentive) / 10_000;
        return config.entryBet - prizeShare - slicerShare;
    }
}
