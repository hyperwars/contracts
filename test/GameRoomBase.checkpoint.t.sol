// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomCheckpointTest is GameRoomBaseTestBase {
    function test_checkpoint_revertsWhenNotActive() public {
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.checkpoint();
    }

    function test_checkpoint_emitsEvent() public {
        _fillAndStart();
        vm.expectEmit(false, false, false, true);
        emit IGameRoom.Checkpointed(block.number);
        room.checkpoint();
    }

    function test_checkpoint_scoresZeroWhenNoPositions() public {
        _fillAndStart();
        room.checkpoint();
        assertEq(room.getPlayerScore(alice), 0);
        assertEq(room.getPlayerScore(bob), 0);
    }

    function test_checkpoint_accumulatesScoreFromPositions() public {
        _fillAndStart();

        // First checkpoint: positions captured; score delta = szi(t-1=0) * pxDelta = 0
        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        _mockPositionOpen(room.playerProxy(bob), BTC_PERP, 50);
        room.checkpoint();

        // Price moves up by 1_000 units
        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);

        // Second checkpoint: score += szi(t-1) * pxDelta
        // alice: 100 * 1_000 = 100_000; bob: 50 * 1_000 = 50_000
        room.checkpoint();

        assertEq(room.getPlayerScore(alice), 100_000);
        assertEq(room.getPlayerScore(bob), 50_000);
    }

    function test_checkpoint_shortPositionLosesOnPriceRise() public {
        _fillAndStart();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, -100);
        room.checkpoint();

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);
        room.checkpoint();

        assertEq(room.getPlayerScore(alice), -100_000);
    }

    function test_checkpoint_skipsEliminatedPlayers() public {
        _fillAndStart();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        // Bob has lowest forced score — eliminated first
        room.forceScore(alice, 100e6);
        room.forceScore(bob, 50e6);
        room.forceScore(carol, 150e6);
        room.forceScore(dave, 200e6);
        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper);
        room.slice(assets);
        assertTrue(room.isEliminated(bob));

        // Switch to real checkpoint scoring
        room.clearForcedScore();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        _mockPositionOpen(room.playerProxy(bob), BTC_PERP, 9999); // eliminated — ignored
        _mockPositionOpen(room.playerProxy(carol), BTC_PERP, 150);
        _mockPositionOpen(room.playerProxy(dave), BTC_PERP, 200);

        room.checkpoint();
        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);
        room.checkpoint();

        assertEq(room.getPlayerScore(bob), 0); // eliminated — never scored
        assertEq(room.getPlayerScore(alice), 100_000);
    }

    // --- live delta ---

    function test_checkpoint_liveScoreReflectsMoveBetweenCheckpoints() public {
        _fillAndStart();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        room.checkpoint(); // t0: last szi=100, last mark=BTC_PRICE

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 500); // price moves, no checkpoint yet

        // live delta = 100 * 500 = 50_000
        assertEq(room.getPlayerScore(alice), 50_000);
    }

    function test_checkpoint_liveScoreFallsToZeroAfterCheckpoint() public {
        _fillAndStart();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        room.checkpoint(); // t0

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 500);
        room.checkpoint(); // t1: accumulates 100*500=50_000; resets live delta to 0

        // After checkpoint the accumulated score is 50_000 and live delta is 0
        assertEq(room.getPlayerScore(alice), 50_000);
    }

    function test_checkpoint_liveScoreEliminatedPlayerIgnored() public {
        _fillAndStart();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        room.forceScore(alice, 200e6);
        room.forceScore(bob, 10e6); // bob lowest
        room.forceScore(carol, 150e6);
        room.forceScore(dave, 100e6);
        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper);
        room.slice(assets);
        assertTrue(room.isEliminated(bob));

        room.clearForcedScore();

        // With bob eliminated, getPlayerScore returns frozen accumulator (0) regardless of price
        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 100_000);
        assertEq(room.getPlayerScore(bob), 0);
    }

    // --- telescoping ---

    function test_checkpoint_telescopingMultiInterval() public {
        _fillAndStart();

        // Position opens; t0 captures szi=1
        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 1);
        room.checkpoint(); // t0: score += 0*0 = 0; szi->1; mark->BTC_PRICE

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 100);
        room.checkpoint(); // t1: score += 1*100=100

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 250);
        room.checkpoint(); // t2: score += 1*150=250 (total=250)

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 300);
        _mockPositionClosed(room.playerProxy(alice), BTC_PERP); // close
        room.checkpoint(); // t3: score += 1*50=50 (total=300); szi->0

        // Total = 300 = (BTC_PRICE+300 - BTC_PRICE)*1 — telescoping holds
        assertEq(room.getPlayerScore(alice), 300);
    }

    // --- realized PnL on close ---

    function test_checkpoint_realizedPnlCapturedOnClose() public {
        _fillAndStart();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 50);
        room.checkpoint(); // t0: szi=50 captured

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 200);
        _mockPositionClosed(room.playerProxy(alice), BTC_PERP); // close before t1

        room.checkpoint(); // t1: score += 50*(+200)=10_000; szi->0

        // Score = 10_000 even though position is now closed
        assertEq(room.getPlayerScore(alice), 10_000);
    }

    // --- injection immunity ---

    function test_checkpoint_injectionDoesNotAffectScore() public {
        _fillAndStart();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        room.checkpoint(); // t0

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);
        room.checkpoint(); // t1: score=100_000

        // Simulate deposit injection: mock huge accountValue / rawUsd
        PrecompileLib.AccountMarginSummary memory injected = PrecompileLib.AccountMarginSummary({
            accountValue: 5_000_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 5_000_000_000
        });
        vm.mockCall(
            HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.DEFAULT_PERP_DEX), room.playerProxy(alice)),
            abi.encode(injected)
        );

        // Score formula never reads accountValue — injection is invisible
        assertEq(room.getPlayerScore(alice), 100_000);
    }

    function test_checkpoint_injectionBeforeCheckpointDoesNotAffectScore() public {
        _fillAndStart();

        // Inject before any checkpoint
        PrecompileLib.AccountMarginSummary memory injected = PrecompileLib.AccountMarginSummary({
            accountValue: 9_999_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 9_999_000_000
        });
        vm.mockCall(
            HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.DEFAULT_PERP_DEX), room.playerProxy(alice)),
            abi.encode(injected)
        );

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        room.checkpoint(); // t0

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 500);
        room.checkpoint(); // t1: score = 100*500 = 50_000

        assertEq(room.getPlayerScore(alice), 50_000);
    }

    // --- conservative gap behavior ---

    function test_checkpoint_intraIntervalRoundTripScoresZero() public {
        _fillAndStart();

        // No position at t0
        room.checkpoint(); // t0: szi=0 captured

        // Open and close between checkpoints (intra-interval round-trip)
        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        _mockPositionClosed(room.playerProxy(alice), BTC_PERP); // immediately closed

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);
        room.checkpoint(); // t1: sziPrev=0, score += 0*1000 = 0

        assertEq(room.getPlayerScore(alice), 0);
    }

    function test_checkpoint_positionOpenedJustBeforePhotoEarnsNothingForPrecedingInterval() public {
        _fillAndStart();

        room.checkpoint(); // t0: szi=0

        // Open position AFTER t0 checkpoint but BEFORE t1
        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);

        // Even with price move, the interval [t0,t1] credits 0 because szi at t0 was 0
        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 2_000);
        room.checkpoint(); // t1: sziPrev=0, score += 0

        // Score at t1 is 0 (no credit for the interval before position was visible)
        assertEq(room.getPlayerScore(alice), 0);
    }

    // --- liquidation ---

    function test_checkpoint_liquidationRetainsAccumulatedLoss() public {
        _fillAndStart();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, 100);
        room.checkpoint(); // t0: szi=100

        // Price drops — position gets liquidated (szi → 0)
        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE - 500);
        _mockPositionClosed(room.playerProxy(alice), BTC_PERP);

        room.checkpoint(); // t1: score += 100*(-500) = -50_000; szi->0

        assertEq(room.getPlayerScore(alice), -50_000);
    }

    // --- permissionless ---

    function test_checkpoint_anyCallerSucceeds() public {
        _fillAndStart();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        room.checkpoint(); // permissionless — must not revert
    }

    // --- fuzz: injection immunity ---

    function testFuzz_checkpoint_injectionImmunity(int64 szi, uint64 pxUp) public {
        szi = int64(bound(int256(szi), -100_000, 100_000));
        pxUp = uint64(bound(uint256(pxUp), 0, 10_000));

        _fillAndStart();

        _mockPositionOpen(room.playerProxy(alice), BTC_PERP, szi);
        room.checkpoint(); // t0

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + pxUp);

        // Inject massive accountValue — must not affect score
        PrecompileLib.AccountMarginSummary memory injected = PrecompileLib.AccountMarginSummary({
            accountValue: 1_000_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 1_000_000_000
        });
        vm.mockCall(
            HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.DEFAULT_PERP_DEX), room.playerProxy(alice)),
            abi.encode(injected)
        );

        room.checkpoint(); // t1

        int256 expected = int256(szi) * int256(uint256(pxUp));
        assertEq(room.getPlayerScore(alice), expected);
    }
}
