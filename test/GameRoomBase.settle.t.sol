// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomSettleTest is GameRoomBaseTestBase {
    uint256 constant MAX_ROUND_DURATION = 1000;

    function test_settleByTimeLimit_setsWinnerToHighestEquity() public {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 300e6);
        _mockPlayerScore(dave, 200e6);

        vm.roll(block.number + MAX_ROUND_DURATION);
        room.settleByTimeLimit();

        assertEq(room.winner(), carol);
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.REVOKING_AGENTS));
    }

    function test_settleByTimeLimit_tieBreaksByFirstJoined() public {
        _fillAndStart();
        // alice and carol have same score; alice joined first
        _mockPlayerScore(alice, 200e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 200e6);
        _mockPlayerScore(dave, 100e6);

        vm.roll(block.number + MAX_ROUND_DURATION);
        room.settleByTimeLimit();

        assertEq(room.winner(), alice);
    }

    function test_settleByTimeLimit_revertsIfNotActive() public {
        _joinPlayer(alice);
        // Still in LOBBY
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.settleByTimeLimit();
    }

    function test_settleByTimeLimit_revertsIfRoundNotExpired() public {
        _fillAndStart();

        vm.expectRevert(IGameRoom.RoundNotExpired.selector);
        room.settleByTimeLimit();
    }

    function test_settleByTimeLimit_emitsRoundSettled() public {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 300e6);
        _mockPlayerScore(dave, 200e6);

        vm.roll(block.number + MAX_ROUND_DURATION);

        vm.expectEmit(true, false, false, true);
        emit IGameRoom.RoundSettled(carol, IGameRoom.SettleReason.TimeLimit);
        room.settleByTimeLimit();
    }

    function test_settleByTimeLimit_withEliminatedPlayers() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets); // eliminates bob

        // Now 3 active: alice, carol, dave
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);

        vm.roll(block.number + MAX_ROUND_DURATION);
        room.settleByTimeLimit();

        assertEq(room.winner(), dave);
        // bob should not win even though eliminated
        assertTrue(room.isEliminated(bob));
    }

    function test_settleByTimeLimit_revertsIfAlreadySettling() public {
        _sliceToLastMan();
        // state is CLOSING_POSITIONS, not ACTIVE
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.settleByTimeLimit();
    }

    function test_finalSlice_setsWinner() public {
        _sliceToLastMan();
        assertEq(room.winner(), dave);
    }

    function test_finalSlice_emitsRoundSettled() public {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        // Slice bob (4→3)
        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper);
        room.slice(assets);

        // Slice alice (3→2)
        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(alice, 30e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);
        vm.prank(keeper);
        room.slice(assets);

        // Final slice: carol (2→1)
        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(carol, 100e6);
        _mockPlayerScore(dave, 200e6);

        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit IGameRoom.RoundSettled(dave, IGameRoom.SettleReason.LastManStanding);
        room.slice(assets);
    }

    function test_advance_closing_staysIfPositionsOpen() public {
        _sliceToLastMan();

        // Mock dave's proxy with open position
        _mockPositionOpen(room.playerProxy(dave), BTC_PERP, 100);

        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.CLOSING_POSITIONS));
    }

    function test_advance_closing_advancesToWithdrawing() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();

        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.WITHDRAWING));
    }

    function test_advance_closing_emitsEvent() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();

        vm.expectEmit(false, false, false, true);
        emit IGameRoom.SettlementAdvanced(IGameRoom.RoundState.WITHDRAWING);
        room.advanceSettlement();
    }

    function test_advance_withdrawing_staysIfFundsRemain() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement(); // → WITHDRAWING

        // Don't mock withdrawable/spotBalance as zero — defaults may cause issues
        // Mock one proxy with non-zero withdrawable
        address daveProxy = room.playerProxy(dave);
        vm.mockCall(HLConstants.WITHDRAWABLE_PRECOMPILE_ADDRESS, abi.encode(daveProxy), abi.encode(uint64(1000)));

        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.WITHDRAWING));
    }

    function test_advance_withdrawing_advancesWithUnbridgeableDust() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement(); // → WITHDRAWING

        _setSpotDustForAll(100_000_000); // 1.0 USDC, below the 1.1 USDC floor

        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.DISTRIBUTING));
    }

    function test_advance_withdrawing_blocksAboveFloorUntilBridged() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement(); // → WITHDRAWING

        _setSpotDustForAll(200_000_000); // 2.0 USDC, above the floor
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.WITHDRAWING));

        _setSpotDustForAll(1_000_000); // residue after the bridge completes
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.DISTRIBUTING));
    }

    function test_advance_withdrawing_advancesToDistributing() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement(); // → WITHDRAWING

        _mockAllFundsWithdrawn();
        room.advanceSettlement(); // → DISTRIBUTING

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.DISTRIBUTING));
    }

    function test_advance_withdrawing_emitsEvent() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement(); // → WITHDRAWING

        _mockAllFundsWithdrawn();

        vm.expectEmit(false, false, false, true);
        emit IGameRoom.SettlementAdvanced(IGameRoom.RoundState.DISTRIBUTING);
        room.advanceSettlement();
    }

    function test_advance_distributing_paysWinner() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement(); // → WITHDRAWING
        _mockAllFundsWithdrawn();
        room.advanceSettlement(); // → DISTRIBUTING

        // Simulate bridged funds arriving at proxies
        address usdc = HLConstants.usdc();
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            deal(usdc, room.playerProxy(players[i]), 10e6);
        }

        uint256 roomBalBefore = IERC20(usdc).balanceOf(address(room));
        uint256 expectedTotal = roomBalBefore + 10e6 * players.length;

        room.advanceSettlement(); // → FINISHED

        assertEq(IERC20(usdc).balanceOf(dave), expectedTotal);
        assertEq(IERC20(usdc).balanceOf(address(room)), 0);
    }

    function test_advance_distributing_includesLeftoverSlicerReserve() public {
        // Time-limit scenario: not all players sliced, leftover reserve exists
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 300e6);
        _mockPlayerScore(dave, 200e6);

        vm.roll(block.number + MAX_ROUND_DURATION);
        room.settleByTimeLimit(); // carol wins

        uint256 slicerReserveBefore = room.slicerReserve();
        assertGt(slicerReserveBefore, 0);

        _advancePastRevocation();
        _mockAllPositionsClosed();
        room.advanceSettlement(); // → WITHDRAWING
        _mockAllFundsWithdrawn();
        room.advanceSettlement(); // → DISTRIBUTING

        // Simulate bridged funds
        address usdc = HLConstants.usdc();
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            deal(usdc, room.playerProxy(players[i]), 10e6);
        }

        uint256 roomBal = IERC20(usdc).balanceOf(address(room));
        uint256 expectedTotal = roomBal + 10e6 * players.length;

        room.advanceSettlement(); // → FINISHED

        // Carol gets prizePool + slicerReserve + swept balances
        assertEq(IERC20(usdc).balanceOf(carol), expectedTotal);
    }

    function test_advance_distributing_transitionsToFinished() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement();
        _mockAllFundsWithdrawn();
        room.advanceSettlement();
        room.advanceSettlement();

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));
    }

    function test_advance_distributing_emitsEvents() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement();
        _mockAllFundsWithdrawn();
        room.advanceSettlement();

        uint256 expectedPayout = IERC20(HLConstants.usdc()).balanceOf(address(room));

        vm.expectEmit(true, false, false, true);
        emit IGameRoom.PrizeDistributed(dave, expectedPayout);
        vm.expectEmit(true, false, false, true);
        emit IGameRoom.RoundFinished(dave, expectedPayout);
        room.advanceSettlement();
    }

    function test_advanceSettlement_revertsIfNotSettling() public {
        // LOBBY state
        vm.expectRevert(IGameRoom.NotSettling.selector);
        room.advanceSettlement();
    }

    function test_advanceSettlement_revertsIfActive() public {
        _fillAndStart();
        vm.expectRevert(IGameRoom.NotSettling.selector);
        room.advanceSettlement();
    }

    function test_advanceSettlement_revertsIfFinished() public {
        _sliceToLastMan();
        _mockAllPositionsClosed();
        room.advanceSettlement();
        _mockAllFundsWithdrawn();
        room.advanceSettlement();
        room.advanceSettlement(); // → FINISHED

        vm.expectRevert(IGameRoom.NotSettling.selector);
        room.advanceSettlement();
    }

    function test_fullSettlement_lms() public {
        address usdc = HLConstants.usdc();
        uint256 totalDeposited = ENTRY_BET * 4;

        _sliceToLastMan();
        assertEq(room.winner(), dave);

        // Phase 1: CLOSING
        _mockAllPositionsClosed();
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.WITHDRAWING));

        // Phase 2: WITHDRAWING
        _mockAllFundsWithdrawn();
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.DISTRIBUTING));

        // Simulate bridged funds
        address[] memory players = room.getPlayers();
        uint256 tradingPerPlayer = _tradingBalPerPlayer();
        for (uint256 i; i < players.length; ++i) {
            deal(usdc, room.playerProxy(players[i]), tradingPerPlayer);
        }

        // Phase 3: DISTRIBUTING
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));

        // Accounting: keeper got slicer incentives during slicing, dave gets the rest
        uint256 keeperBal = IERC20(usdc).balanceOf(keeper);
        uint256 winnerBal = IERC20(usdc).balanceOf(dave);
        assertEq(keeperBal + winnerBal, totalDeposited);
        assertEq(IERC20(usdc).balanceOf(address(room)), 0);
    }

    function test_fullSettlement_timeLimit() public {
        address usdc = HLConstants.usdc();

        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 300e6);
        _mockPlayerScore(dave, 200e6);

        // Slice bob first
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper);
        room.slice(assets);

        // Time limit expires
        vm.roll(block.number + MAX_ROUND_DURATION);
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(carol, 300e6);
        _mockPlayerScore(dave, 200e6);
        room.settleByTimeLimit();
        assertEq(room.winner(), carol);

        // Advance through phases
        _advancePastRevocation();
        _mockAllPositionsClosed();
        room.advanceSettlement();
        _mockAllFundsWithdrawn();
        room.advanceSettlement();

        // Simulate bridged funds
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            deal(usdc, room.playerProxy(players[i]), _tradingBalPerPlayer());
        }

        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));
        assertGt(IERC20(usdc).balanceOf(carol), 0);
        assertEq(IERC20(usdc).balanceOf(address(room)), 0);
    }

    function testFuzz_settleByTimeLimit_timing(uint256 blocksAfterStart) public {
        blocksAfterStart = bound(blocksAfterStart, 0, MAX_ROUND_DURATION * 2);

        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);

        vm.roll(block.number + blocksAfterStart);

        if (blocksAfterStart < MAX_ROUND_DURATION) {
            vm.expectRevert(IGameRoom.RoundNotExpired.selector);
            room.settleByTimeLimit();
        } else {
            room.settleByTimeLimit();
            assertEq(room.winner(), dave);
        }
    }

    function testFuzz_settleByTimeLimit_winnerIsHighest(int64 scoreA, int64 scoreB, int64 scoreC, int64 scoreD) public {
        scoreA = int64(bound(int256(scoreA), 1e6, 1000e6));
        scoreB = int64(bound(int256(scoreB), 1e6, 1000e6));
        scoreC = int64(bound(int256(scoreC), 1e6, 1000e6));
        scoreD = int64(bound(int256(scoreD), 1e6, 1000e6));

        _fillAndStart();
        _mockPlayerScore(alice, scoreA);
        _mockPlayerScore(bob, scoreB);
        _mockPlayerScore(carol, scoreC);
        _mockPlayerScore(dave, scoreD);

        vm.roll(block.number + MAX_ROUND_DURATION);
        room.settleByTimeLimit();

        // Find expected winner (first-joined with highest score)
        int64[4] memory scores = [scoreA, scoreB, scoreC, scoreD];
        address[4] memory players = [alice, bob, carol, dave];
        address expected;
        int64 best = type(int64).min;
        for (uint256 i; i < 4; ++i) {
            if (scores[i] > best) {
                best = scores[i];
                expected = players[i];
            }
        }

        assertEq(room.winner(), expected);
    }
}
