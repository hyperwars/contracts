// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomConfigTest is GameRoomBaseTestBase {
    function test_initialize_revertsIfEmptyAllowedAssets() public {
        DefaultGameRoom badRoom = new DefaultGameRoom();
        uint32[] memory emptyAssets = new uint32[](0);

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: MIN_PLAYERS,
            maxPlayers: MAX_PLAYERS,
            allowedAssets: emptyAssets,
            builderAddress: address(0),
            builderFeeRate: 0
        });

        vm.expectRevert(IGameRoom.EmptyAllowedAssets.selector);
        badRoom.initialize(config, address(proxyImpl));
    }
}
