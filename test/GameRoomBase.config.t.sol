// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomConfigTest is GameRoomBaseTestBase {
    function test_initialize_revertsIfSplitExceeds100() public {
        DefaultGameRoom badRoom = new DefaultGameRoom();
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: 9500,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: 600,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: MIN_PLAYERS,
            maxPlayers: MAX_PLAYERS,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });

        vm.expectRevert(IGameRoom.InvalidConfig.selector);
        badRoom.initialize(config, address(proxyImpl));
    }

    function test_initialize_allowsMaxValidSplit() public {
        DefaultGameRoom okRoom = new DefaultGameRoom();
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: 9800,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: 100,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: MIN_PLAYERS,
            maxPlayers: MAX_PLAYERS,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });

        okRoom.initialize(config, address(proxyImpl));
        assertEq(uint256(okRoom.state()), uint256(IGameRoom.RoundState.LOBBY));
    }

    function test_initialize_revertsIfEmptyAllowedAssets() public {
        DefaultGameRoom badRoom = new DefaultGameRoom();
        uint32[] memory emptyAssets = new uint32[](0);

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: PRIZE_POOL_SHARE,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: SLICER_INCENTIVE,
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
