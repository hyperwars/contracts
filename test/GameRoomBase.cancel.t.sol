// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomCancelTest is GameRoomBaseTestBase {
    function test_cancel_transitionsToCancelled() public {
        _register(alice);
        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.CANCELLED));
    }

    function test_cancel_revertsIfMinPlayersMet() public {
        _registerMin();
        vm.roll(block.number + JOIN_WINDOW);
        vm.expectRevert(IGameRoom.MinPlayersReached.selector);
        room.cancel();
    }

    function test_cancel_revertsBeforeJoinWindow() public {
        _register(alice);
        vm.expectRevert(IGameRoom.JoinWindowNotElapsed.selector);
        room.cancel();
    }

    function test_cancel_emitsEvent() public {
        _register(alice);
        vm.roll(block.number + JOIN_WINDOW);
        vm.expectEmit(false, false, false, true);
        emit IGameRoom.RoundCancelled(1);
        room.cancel();
    }

    function _cancelWithAlice() internal {
        _register(alice);
        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();
    }

    function test_refund_returnsStakeToPlayerCoreAccount() public {
        _cancelWithAlice();
        hyperCore.forceAccountActivation(alice);

        room.refund(alice);
        CoreSimulatorLib.nextBlock();

        assertEq(PrecompileLib.spotBalance(alice, HLConstants.USDC_TOKEN_INDEX).total, uint64(ENTRY_BET));
        assertEq(_spotOf(alice), 0);
    }

    function test_refund_permissionlessCaller() public {
        _cancelWithAlice();
        hyperCore.forceAccountActivation(alice);

        vm.prank(makeAddr("randomCaller"));
        room.refund(alice);
        CoreSimulatorLib.nextBlock();

        assertEq(PrecompileLib.spotBalance(alice, HLConstants.USDC_TOKEN_INDEX).total, uint64(ENTRY_BET));
    }

    function test_refund_emitsEvent() public {
        _cancelWithAlice();
        address proxy = room.playerProxy(alice);
        vm.expectEmit(true, true, false, false);
        emit IGameRoom.Refunded(alice, proxy);
        room.refund(alice);
    }

    function test_refund_revertsIfNotCancelled() public {
        _register(alice);
        vm.expectRevert(IGameRoom.NotCancelled.selector);
        room.refund(alice);
    }

    function test_refund_revertsIfNotPlayer() public {
        _cancelWithAlice();
        vm.expectRevert(IGameRoom.NotPlayer.selector);
        room.refund(bob);
    }

    function test_refund_revertsIfAlreadyRefunded() public {
        _cancelWithAlice();
        room.refund(alice);
        vm.expectRevert(IGameRoom.AlreadyRefunded.selector);
        room.refund(alice);
    }
}
