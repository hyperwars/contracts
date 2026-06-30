// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IGameRoom} from "../../src/interfaces/IGameRoom.sol";
import {IGameRoomFactory} from "../../src/interfaces/IGameRoomFactory.sol";
import {GameRoomBase} from "../../src/GameRoomBase.sol";

contract MockGameRoomFactory is IGameRoomFactory {
    address public roomImplementation;
    address public lastRoom;
    address private _builderFeeRecipient;

    constructor(address roomImpl, address builderFeeRecipient_) {
        roomImplementation = roomImpl;
        _builderFeeRecipient = builderFeeRecipient_;
    }

    function createRoom(IGameRoom.GameConfig calldata config, address proxyImpl) external returns (address) {
        address room = Clones.clone(roomImplementation);
        GameRoomBase(room).initialize(config, proxyImpl);
        lastRoom = room;
        return room;
    }

    function builderFeeRecipient() external view returns (address) {
        return _builderFeeRecipient;
    }

    function maxPlayers() external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxAssets() external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxRoundDuration() external pure returns (uint256) {
        return type(uint256).max;
    }

    function tradingBalancePerPlayer(IGameRoom.GameConfig calldata config) external pure returns (uint256) {
        uint256 prizeShare = (config.entryBet * config.prizePoolShare) / 10_000;
        uint256 slicerShare = (config.entryBet * config.slicerIncentive) / 10_000;
        return config.entryBet - prizeShare - slicerShare;
    }
}
