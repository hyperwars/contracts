// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomWithdrawTest is GameRoomBaseTestBase {
    function test_canWithdraw_committedPlayerLockedWhileActive() public {
        _fillAndStart();
        assertFalse(room.canWithdraw(alice));
    }

    function test_canWithdraw_releasedAtFinished() public {
        _fillAndStart();
        _finishRound();
        assertTrue(room.canWithdraw(alice));
    }

    function test_canWithdraw_releasedAtCancelled() public {
        _register(alice);
        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();
        assertTrue(room.canWithdraw(alice));
    }

    function test_canWithdraw_neverRegisteredAlwaysAllowed() public {
        _fillAndStart();
        // eve funded a proxy but never registered; her funds are not in any game.
        address eve = makeAddr("eve");
        _fundProxy(eve, uint64(50e6));
        assertTrue(room.canWithdraw(eve));
    }

    function test_withdraw_neverRegisteredRecoversFunds() public {
        _fillAndStart();

        address eve = makeAddr("eve");
        _fundProxy(eve, uint64(50e6));
        hyperCore.forceAccountActivation(eve);

        // Deploy-on-demand: anyone can instantiate the deterministic proxy; withdraw is owner-only.
        address proxy = room.deployProxy(eve);
        vm.prank(eve);
        PlayerProxy(payable(proxy)).withdraw();
        CoreSimulatorLib.nextBlock();

        assertEq(PrecompileLib.spotBalance(eve, HLConstants.USDC_TOKEN_INDEX).total, uint64(50e6));
        assertEq(PrecompileLib.spotBalance(proxy, HLConstants.USDC_TOKEN_INDEX).total, 0);
    }

    function test_withdraw_revertsWhileLocked() public {
        _fillAndStart();
        address proxy = room.playerProxy(alice);
        vm.prank(alice);
        vm.expectRevert(PlayerProxy.WithdrawLocked.selector);
        PlayerProxy(payable(proxy)).withdraw();
    }

    function test_withdraw_revertsForNonOwner() public {
        _fillAndStart();
        _finishRound();
        address proxy = room.playerProxy(alice);
        vm.prank(bob);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        PlayerProxy(payable(proxy)).withdraw();
    }
}
