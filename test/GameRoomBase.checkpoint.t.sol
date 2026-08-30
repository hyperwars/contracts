// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomCheckpointTest is GameRoomBaseTestBase {
    function _proxy(address player) internal view returns (address) {
        return room.playerProxy(player);
    }

    function test_checkpoint_revertsWhenNotActive() public {
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.checkpointPlayer(alice);
    }

    function test_checkpoint_revertsForUnknownPlayer() public {
        _fillAndStart();
        vm.expectRevert(IGameRoom.NotPlayer.selector);
        room.checkpointPlayer(makeAddr("nobody"));
    }

    function test_checkpoint_emitsEvent() public {
        _fillAndStart();
        vm.expectEmit(true, false, false, true);
        emit IGameRoom.Checkpointed(alice, 0);
        room.checkpointPlayer(alice);
    }

    function test_checkpoint_scoresZeroWhenNoPositions() public {
        _fillAndStart();
        room.checkpointPlayer(alice);
        room.checkpointPlayer(bob);
        assertEq(room.getPlayerScore(alice), 0);
        assertEq(room.getPlayerScore(bob), 0);
    }

    function test_checkpoint_accumulatesScoreFromPositions() public {
        _fillAndStart();

        // First checkpoint: positions captured; score delta = szi(t-1=0) * pxDelta = 0
        _mockPositionOpen(_proxy(alice), BTC_PERP, 100);
        _mockPositionOpen(_proxy(bob), BTC_PERP, 50);
        room.checkpointPlayer(alice);
        room.checkpointPlayer(bob);

        // Price moves up by 1_000 units
        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);

        // Second checkpoint: score += szi(t-1) * pxDelta
        // alice: 100 * 1_000 = 100_000; bob: 50 * 1_000 = 50_000
        room.checkpointPlayer(alice);
        room.checkpointPlayer(bob);

        assertEq(room.getPlayerScore(alice), 100_000);
        assertEq(room.getPlayerScore(bob), 50_000);
    }

    function test_checkpoint_shortPositionLosesOnPriceRise() public {
        _fillAndStart();

        _mockPositionOpen(_proxy(alice), BTC_PERP, -100);
        room.checkpointPlayer(alice);

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);
        room.checkpointPlayer(alice);

        assertEq(room.getPlayerScore(alice), -100_000);
    }

    // --- telescoping ---

    function test_checkpoint_telescopingMultiInterval() public {
        _fillAndStart();

        _mockPositionOpen(_proxy(alice), BTC_PERP, 1);
        room.checkpointPlayer(alice); // t0: score += 0*0 = 0; szi->1; mark->BTC_PRICE

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 100);
        room.checkpointPlayer(alice); // t1: score += 1*100=100

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 250);
        room.checkpointPlayer(alice); // t2: score += 1*150=250 (total=250)

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 300);
        _mockPositionClosed(_proxy(alice), BTC_PERP);
        room.checkpointPlayer(alice); // t3: score += 1*50=50 (total=300); szi->0

        assertEq(room.getPlayerScore(alice), 300);
    }

    // --- realized PnL on close ---

    function test_checkpoint_realizedPnlCapturedOnClose() public {
        _fillAndStart();

        _mockPositionOpen(_proxy(alice), BTC_PERP, 50);
        room.checkpointPlayer(alice); // t0: szi=50 captured

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 200);
        _mockPositionClosed(_proxy(alice), BTC_PERP);

        room.checkpointPlayer(alice); // t1: score += 50*(+200)=10_000; szi->0

        assertEq(room.getPlayerScore(alice), 10_000);
    }

    // --- injection immunity ---

    function test_checkpoint_injectionDoesNotAffectScore() public {
        _fillAndStart();

        _mockPositionOpen(_proxy(alice), BTC_PERP, 100);
        room.checkpointPlayer(alice);

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);
        room.checkpointPlayer(alice); // score=100_000

        // Simulate deposit injection: mock huge accountValue / rawUsd
        PrecompileLib.AccountMarginSummary memory injected = PrecompileLib.AccountMarginSummary({
            accountValue: 5_000_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 5_000_000_000
        });
        vm.mockCall(
            HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.DEFAULT_PERP_DEX), _proxy(alice)),
            abi.encode(injected)
        );

        // Score formula never reads accountValue — injection is invisible
        assertEq(room.getPlayerScore(alice), 100_000);
    }

    // --- conservative gap behavior ---

    function test_checkpoint_intraIntervalRoundTripScoresZero() public {
        _fillAndStart();

        room.checkpointPlayer(alice); // t0: szi=0 captured

        _mockPositionOpen(_proxy(alice), BTC_PERP, 100);
        _mockPositionClosed(_proxy(alice), BTC_PERP); // immediately closed

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 1_000);
        room.checkpointPlayer(alice); // t1: sziPrev=0, score += 0*1000 = 0

        assertEq(room.getPlayerScore(alice), 0);
    }

    function test_checkpoint_positionOpenedJustBeforePhotoEarnsNothingForPrecedingInterval() public {
        _fillAndStart();

        room.checkpointPlayer(alice); // t0: szi=0

        _mockPositionOpen(_proxy(alice), BTC_PERP, 100);

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + 2_000);
        room.checkpointPlayer(alice); // t1: sziPrev=0, score += 0

        assertEq(room.getPlayerScore(alice), 0);
    }

    // --- liquidation ---

    function test_checkpoint_liquidationRetainsAccumulatedLoss() public {
        _fillAndStart();

        _mockPositionOpen(_proxy(alice), BTC_PERP, 100);
        room.checkpointPlayer(alice); // t0: szi=100

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE - 500);
        _mockPositionClosed(_proxy(alice), BTC_PERP);

        room.checkpointPlayer(alice); // t1: score += 100*(-500) = -50_000; szi->0

        assertEq(room.getPlayerScore(alice), -50_000);
    }

    // --- permissionless ---

    function test_checkpoint_anyCallerSucceeds() public {
        _fillAndStart();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        room.checkpointPlayer(alice); // permissionless — must not revert
    }

    // --- fuzz: injection immunity ---

    function testFuzz_checkpoint_injectionImmunity(int64 szi, uint64 pxUp) public {
        szi = int64(bound(int256(szi), -100_000, 100_000));
        pxUp = uint64(bound(uint256(pxUp), 0, 10_000));

        _fillAndStart();

        _mockPositionOpen(_proxy(alice), BTC_PERP, szi);
        room.checkpointPlayer(alice); // t0

        hyperCore.setMarkPx(BTC_PERP, BTC_PRICE + pxUp);

        PrecompileLib.AccountMarginSummary memory injected = PrecompileLib.AccountMarginSummary({
            accountValue: 1_000_000_000, marginUsed: 0, ntlPos: 0, rawUsd: 1_000_000_000
        });
        vm.mockCall(
            HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.DEFAULT_PERP_DEX), _proxy(alice)),
            abi.encode(injected)
        );

        room.checkpointPlayer(alice); // t1

        int256 expected = int256(szi) * int256(uint256(pxUp));
        assertEq(room.getPlayerScore(alice), expected);
    }
}
