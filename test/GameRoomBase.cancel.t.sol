// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomCancelTest is GameRoomBaseTestBase {
    function test_cancel_transitionsToCancelled() public {
        _joinPlayer(alice);

        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.CANCELLED));
    }

    function test_cancel_revertsIfMinPlayersMet() public {
        _joinPlayer(alice);
        _joinPlayer(bob);

        vm.roll(block.number + JOIN_WINDOW);
        vm.expectRevert(IGameRoom.MinPlayersReached.selector);
        room.cancel();
    }

    function test_cancel_revertsBeforeJoinWindow() public {
        _joinPlayer(alice);

        vm.expectRevert(IGameRoom.JoinWindowNotElapsed.selector);
        room.cancel();
    }

    function test_cancel_emitsEvent() public {
        _joinPlayer(alice);
        vm.roll(block.number + JOIN_WINDOW);

        vm.expectEmit(false, false, false, true);
        emit IGameRoom.RoundCancelled(1);
        room.cancel();
    }

    function test_claimRefund_returnsEntryBet() public {
        _joinPlayer(alice);

        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();

        vm.prank(alice);
        room.claimRefund();

        assertEq(IERC20(HLConstants.usdc()).balanceOf(alice), ENTRY_BET);
    }

    function test_claimRefund_revertsIfNotCancelled() public {
        _joinPlayer(alice);

        vm.prank(alice);
        vm.expectRevert(IGameRoom.NotCancelled.selector);
        room.claimRefund();
    }

    function test_claimRefund_revertsIfNotPlayer() public {
        _joinPlayer(alice);
        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();

        vm.prank(bob);
        vm.expectRevert(IGameRoom.NotPlayer.selector);
        room.claimRefund();
    }

    function test_claimRefund_revertsIfAlreadyRefunded() public {
        _joinPlayer(alice);
        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();

        vm.prank(alice);
        room.claimRefund();

        vm.prank(alice);
        vm.expectRevert(IGameRoom.AlreadyRefunded.selector);
        room.claimRefund();
    }

    function test_claimRefund_emitsEvent() public {
        _joinPlayer(alice);
        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit IGameRoom.RefundClaimed(alice, ENTRY_BET);
        room.claimRefund();
    }
}
