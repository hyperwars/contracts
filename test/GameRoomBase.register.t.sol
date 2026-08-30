// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomRegisterTest is GameRoomBaseTestBase {
    function test_register_recordsPlayerAndProxy() public {
        _register(alice);

        assertTrue(room.hasJoined(alice));
        assertEq(room.getPlayerCount(), 1);
        assertEq(room.playerProxy(alice), room.predictProxy(alice));

        address[] memory players = room.getPlayers();
        assertEq(players.length, 1);
        assertEq(players[0], alice);
    }

    function test_register_emitsEvent() public {
        address proxy = _fundProxy(alice, uint64(ENTRY_BET));

        vm.expectEmit(true, true, false, true);
        emit IGameRoom.PlayerRegistered(alice, proxy, 1);
        room.register(alice);
    }

    function test_register_permissionlessCaller() public {
        _fundProxy(alice, uint64(ENTRY_BET));
        vm.prank(makeAddr("randomCaller"));
        room.register(alice);
        assertTrue(room.hasJoined(alice));
    }

    function test_register_revertsIfUnderfunded() public {
        _fundProxy(alice, uint64(ENTRY_BET) - 1);
        vm.expectRevert(IGameRoom.Underfunded.selector);
        room.register(alice);
    }

    function test_register_revertsIfAlreadyRegistered() public {
        _register(alice);
        vm.expectRevert(IGameRoom.AlreadyRegistered.selector);
        room.register(alice);
    }

    function test_register_revertsIfNotLobby() public {
        _fillAndStart();
        _fundProxy(makeAddr("late"), uint64(ENTRY_BET));
        vm.expectRevert(IGameRoom.NotInLobby.selector);
        room.register(makeAddr("late"));
    }

    function test_register_autoStartsWhenFull() public {
        _register(alice);
        _register(bob);
        _register(carol);
        _register(dave);
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.STARTING));
    }

    function test_register_doesNotDeployProxy() public {
        _register(alice);
        // Proxy is only predicted at registration; deployment is deferred to activation.
        assertFalse(room.isProxyDeployed(alice));
    }

    function test_startRound_transitionsToStarting() public {
        _registerMin();
        vm.roll(block.number + JOIN_WINDOW);
        room.startRound();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.STARTING));
    }

    function test_startRound_revertsBeforeJoinWindow() public {
        _registerMin();
        vm.expectRevert(IGameRoom.JoinWindowNotElapsed.selector);
        room.startRound();
    }

    function test_startRound_revertsIfBelowMinPlayers() public {
        _register(alice);
        vm.roll(block.number + JOIN_WINDOW);
        vm.expectRevert(IGameRoom.BelowMinPlayers.selector);
        room.startRound();
    }

    function test_startRound_emitsEvent() public {
        _registerMin();
        vm.roll(block.number + JOIN_WINDOW);
        vm.expectEmit(false, false, false, true);
        emit IGameRoom.RoundStarting(2);
        room.startRound();
    }

    function testFuzz_register_multiplePlayers(uint8 count) public {
        count = uint8(bound(count, 1, MAX_PLAYERS - 1));
        for (uint8 i; i < count; ++i) {
            _register(makeAddr(string(abi.encodePacked("player", i))));
        }
        assertEq(room.getPlayerCount(), count);
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.LOBBY));
    }

    function test_proxyInitializedOnActivation() public {
        _fillAndStart();
        address proxyAddr = room.playerProxy(alice);
        PlayerProxy proxy = PlayerProxy(payable(proxyAddr));
        assertEq(proxy.owner(), alice);
        assertEq(proxy.gameRoom(), address(room));
    }
}
