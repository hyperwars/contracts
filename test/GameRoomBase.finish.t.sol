// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomFinishTest is GameRoomBaseTestBase {
    function test_finish_revertsWhenNotActive() public {
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.finish();
    }

    function test_finish_revertsBeforeRoundExpires() public {
        _fillAndStart();
        vm.expectRevert(IGameRoom.RoundNotExpired.selector);
        room.finish();
    }

    function test_finish_transitionsToFinished() public {
        _fillAndStart();
        vm.roll(room.roundStartBlock() + MAX_ROUND_DURATION);
        room.finish();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));
    }

    function test_finish_emitsEvent() public {
        _fillAndStart();
        vm.roll(room.roundStartBlock() + MAX_ROUND_DURATION);
        vm.expectEmit(false, false, false, false);
        emit IGameRoom.RoundFinished();
        room.finish();
    }

    function test_finish_permissionlessCaller() public {
        _fillAndStart();
        vm.roll(room.roundStartBlock() + MAX_ROUND_DURATION);
        vm.prank(makeAddr("randomCaller"));
        room.finish();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));
    }

    function test_finish_revertsIfCalledTwice() public {
        _fillAndStart();
        _finishRound();
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.finish();
    }

    // Free-play: finishing releases every committed player; the base never touches funds.
    function test_finish_releasesEveryPlayer() public {
        _fillAndStart();
        assertFalse(room.canWithdraw(alice));

        _finishRound();

        assertTrue(room.canWithdraw(alice));
        assertTrue(room.canWithdraw(bob));
        assertTrue(room.canWithdraw(carol));
        assertTrue(room.canWithdraw(dave));
    }
}
