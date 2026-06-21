// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomRevokeTest is GameRoomBaseTestBase {
    uint256 constant MAX_ROUND_DURATION = 1000;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    function _coreWriterLogCount(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == CORE_WRITER) ++count;
        }
    }

    function _settleByTime() internal {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 300e6);
        _mockPlayerScore(dave, 200e6);
        vm.roll(block.number + MAX_ROUND_DURATION);
        room.settleByTimeLimit();
    }

    function test_settleByTimeLimit_entersRevokingAgents() public {
        _settleByTime();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.REVOKING_AGENTS));
        assertEq(room.settlementBlock(), block.number);
    }

    function test_finalSlice_entersRevokingAgents() public {
        _setupSliceScenario();
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        vm.prank(keeper);
        room.slice(assets); // 4 -> 3

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(alice, 30e6);
        vm.prank(keeper);
        room.slice(assets); // 3 -> 2

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(carol, 100e6);
        vm.prank(keeper);
        room.slice(assets); // 2 -> 1, final

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.REVOKING_AGENTS));
    }

    // _enterRevoking displaces every proxy's agent: one addApiWallet(BURN) CoreWriter
    // action per player. settleByTimeLimit issues no other CoreWriter actions.
    function test_enterRevoking_revokesAllProxies() public {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 300e6);
        _mockPlayerScore(dave, 200e6);
        vm.roll(block.number + MAX_ROUND_DURATION);

        vm.recordLogs();
        room.settleByTimeLimit();
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), room.getPlayerCount());
    }

    // Eliminated players keep a live agent after their slice-time force-close, so they
    // must be revoked too. Slice bob out, then settle: all four proxies are revoked.
    function test_enterRevoking_includesEliminatedPlayers() public {
        _setupSliceScenario();
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets); // eliminates bob
        assertTrue(room.isEliminated(bob));

        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);
        vm.roll(block.number + MAX_ROUND_DURATION);

        vm.recordLogs();
        room.settleByTimeLimit();
        // 4 players total, bob eliminated, all 4 still revoked.
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 4);
    }

    function test_advanceSettlement_staysRevokingBeforeDelay() public {
        _settleByTime();
        vm.roll(room.settlementBlock() + AGENT_REVOCATION_DELAY - 1);
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.REVOKING_AGENTS));
    }

    function test_advanceSettlement_advancesAfterDelay() public {
        _settleByTime();
        vm.roll(room.settlementBlock() + AGENT_REVOCATION_DELAY);
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.CLOSING_POSITIONS));
    }

    function test_revokingPhase_emitsSettlementAdvanced() public {
        _settleByTime();
        vm.roll(room.settlementBlock() + AGENT_REVOCATION_DELAY);

        vm.expectEmit(false, false, false, true);
        emit IGameRoom.SettlementAdvanced(IGameRoom.RoundState.CLOSING_POSITIONS);
        room.advanceSettlement();
    }
}
