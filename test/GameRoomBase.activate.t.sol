// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomActivateTest is GameRoomBaseTestBase {
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    function _coreWriterLogCount(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == CORE_WRITER) ++count;
        }
    }

    function _joinRoom(DefaultGameRoom room_, address player) internal {
        address usdc = HLConstants.usdc();
        deal(usdc, player, ENTRY_BET);
        vm.startPrank(player);
        IERC20(usdc).approve(address(room_), ENTRY_BET);
        room_.join();
        vm.stopPrank();
    }

    // join() must not enqueue any CoreWriter action: the proxy is not yet a known Core user,
    // so Core would silently drop addApiWallet (issue #52).
    function test_join_emitsNoCoreWriterActions() public {
        vm.recordLogs();
        _joinPlayer(alice);
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 0);
    }

    function test_activateAgent_emits() public {
        _fillAndStart();
        address proxy = room.playerProxy(alice);

        vm.expectEmit(true, true, false, false);
        emit IGameRoom.AgentActivated(alice, proxy);
        room.activateAgent(alice);
    }

    function test_activateAgent_enqueuesApiWallet() public {
        _fillAndStart();

        vm.recordLogs();
        room.activateAgent(alice);
        assertGt(_coreWriterLogCount(vm.getRecordedLogs()), 0);
    }

    function test_activateAgent_permissionlessCaller() public {
        _fillAndStart();
        address proxy = room.playerProxy(alice);

        // Anyone can trigger activation for a player; it only authorizes that player's own EOA.
        vm.expectEmit(true, true, false, false);
        emit IGameRoom.AgentActivated(alice, proxy);
        vm.prank(makeAddr("randomCaller"));
        room.activateAgent(alice);
    }

    // Idempotent: Core can silently drop addApiWallet, so a player must be able to retry.
    function test_activateAgent_callableMultipleTimes() public {
        _fillAndStart();
        room.activateAgent(alice);
        room.activateAgent(alice);
    }

    function test_activateAgent_revertsWhenNotActive() public {
        _joinPlayer(alice);
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.activateAgent(alice);
    }

    function test_activateAgent_revertsForUnknownPlayer() public {
        _fillAndStart();
        vm.expectRevert(IGameRoom.NotPlayer.selector);
        room.activateAgent(makeAddr("nobody"));
    }

    function test_activateAgent_approvesBuilderFeeWhenConfigured() public {
        DefaultGameRoom builderRoom = new DefaultGameRoom();

        uint32[] memory allowedAssets = new uint32[](1);
        allowedAssets[0] = BTC_PERP;

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: PRIZE_POOL_SHARE,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: SLICER_INCENTIVE,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: MIN_PLAYERS,
            maxPlayers: MAX_PLAYERS,
            allowedAssets: allowedAssets,
            builderAddress: makeAddr("builder"),
            builderFeeRate: 100
        });
        builderRoom.initialize(config, address(proxyImpl));

        _joinRoom(builderRoom, alice);
        _joinRoom(builderRoom, bob);
        vm.roll(block.number + JOIN_WINDOW);
        builderRoom.startRound();

        vm.recordLogs();
        builderRoom.activateAgent(alice);
        // approveBuilderFee + addApiWallet.
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 2);
    }
}
