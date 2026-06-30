// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGameRoom} from "./IGameRoom.sol";

interface IGameRoomFactory {
    function createRoom(IGameRoom.GameConfig calldata config, address proxyImpl) external returns (address);

    function builderFeeRecipient() external view returns (address);

    function maxPlayers() external view returns (uint256);

    function maxAssets() external view returns (uint256);

    function maxRoundDuration() external view returns (uint256);

    function tradingBalancePerPlayer(IGameRoom.GameConfig calldata config) external pure returns (uint256);
}
