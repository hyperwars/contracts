// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomActivateTest is GameRoomBaseTestBase {
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    function _coreWriterLogCount(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == CORE_WRITER) ++count;
        }
    }

    // register() must not enqueue any CoreWriter action: the proxy is not yet a known Core user,
    // so Core would silently drop addApiWallet (issue #52).
    function test_register_emitsNoCoreWriterActions() public {
        vm.recordLogs();
        _register(alice);
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 0);
    }

    function _fillToStarting() internal {
        _register(alice);
        _register(bob);
        _register(carol);
        _register(dave);
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.STARTING));
    }

    function test_activatePlayer_deploysProxyAndEmits() public {
        _fillToStarting();
        address proxy = room.predictProxy(alice);

        vm.expectEmit(true, true, false, true);
        emit IGameRoom.PlayerActivated(alice, proxy, 1);
        room.activatePlayer(alice);

        assertTrue(room.isActivated(alice));
        assertTrue(room.isProxyDeployed(alice));
    }

    function test_activatePlayer_transitionsToActiveWhenAllDone() public {
        _fillToStarting();
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            room.activatePlayer(players[i]);
        }
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.ACTIVE));
    }

    function test_activatePlayer_enqueuesTransferToPerp() public {
        _fillToStarting();
        vm.recordLogs();
        room.activatePlayer(alice);
        // transferUsdClass moves the entry bet to the perp account.
        assertGt(_coreWriterLogCount(vm.getRecordedLogs()), 0);
        CoreSimulatorLib.nextBlock();
    }

    function test_activatePlayer_revertsWhenNotStarting() public {
        _register(alice);
        vm.expectRevert(IGameRoom.NotStarting.selector);
        room.activatePlayer(alice);
    }

    function test_activatePlayer_revertsForUnknownPlayer() public {
        _fillToStarting();
        vm.expectRevert(IGameRoom.NotPlayer.selector);
        room.activatePlayer(makeAddr("nobody"));
    }

    function test_activatePlayer_revertsIfAlreadyActivated() public {
        _fillToStarting();
        room.activatePlayer(alice);
        vm.expectRevert(IGameRoom.AlreadyActivated.selector);
        room.activatePlayer(alice);
    }

    function test_authorizeAgent_emits() public {
        _fillAndStart();
        address proxy = room.playerProxy(alice);
        vm.expectEmit(true, true, false, false);
        emit IGameRoom.AgentAuthorized(alice, proxy);
        room.authorizeAgent(alice);
    }

    function test_authorizeAgent_enqueuesApiWallet() public {
        _fillAndStart();
        vm.recordLogs();
        room.authorizeAgent(alice);
        assertGt(_coreWriterLogCount(vm.getRecordedLogs()), 0);
    }

    function test_authorizeAgent_permissionlessCaller() public {
        _fillAndStart();
        address proxy = room.playerProxy(alice);
        vm.expectEmit(true, true, false, false);
        emit IGameRoom.AgentAuthorized(alice, proxy);
        vm.prank(makeAddr("randomCaller"));
        room.authorizeAgent(alice);
    }

    // Idempotent: Core can silently drop addApiWallet, so authorization must be retryable.
    function test_authorizeAgent_callableMultipleTimes() public {
        _fillAndStart();
        room.authorizeAgent(alice);
        room.authorizeAgent(alice);
    }

    function test_authorizeAgent_revertsWhenNotActivated() public {
        _fillToStarting();
        vm.expectRevert(IGameRoom.NotActivated.selector);
        room.authorizeAgent(alice);
    }

    function test_activate_approvesBuilderFeeWhenConfigured() public {
        DefaultGameRoom builderRoom = new DefaultGameRoom();

        uint32[] memory allowedAssets = new uint32[](1);
        allowedAssets[0] = BTC_PERP;
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.builderAddress = makeAddr("builder");
        config.builderFeeRate = 100;
        builderRoom.initialize(config, address(proxyImpl));

        address[2] memory two = [alice, bob];
        for (uint256 i; i < two.length; ++i) {
            address proxy = builderRoom.predictProxy(two[i]);
            hyperCore.forceAccountActivation(proxy);
            hyperCore.forceSpotBalance(proxy, HLConstants.USDC_TOKEN_INDEX, uint64(ENTRY_BET));
            builderRoom.register(two[i]);
        }
        vm.roll(block.number + JOIN_WINDOW);
        builderRoom.startRound();

        vm.recordLogs();
        builderRoom.activatePlayer(alice);
        // approveBuilderFee + transferUsdClass.
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 2);
        CoreSimulatorLib.nextBlock();
    }
}
