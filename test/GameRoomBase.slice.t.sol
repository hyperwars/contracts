// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {HarnessGameRoom} from "./mocks/HarnessGameRoom.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomSliceTest is GameRoomBaseTestBase {
    function test_validateTrade_returnsTrueWhenActive() public {
        _fillAndStart();
        assertTrue(room.validateTrade(alice, BTC_PERP));
    }

    function test_validateTrade_returnsFalseWhenNotActive() public {
        _joinPlayer(alice);
        assertFalse(room.validateTrade(alice, BTC_PERP));
    }

    function test_validateTrade_returnsFalseWhenEliminated() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        // Bob was eliminated (lowest score)
        assertFalse(room.validateTrade(bob, BTC_PERP));
        // Alice still active
        assertTrue(room.validateTrade(alice, BTC_PERP));
    }

    function test_slice_eliminatesLowestScorer() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        assertTrue(room.isEliminated(bob));
        assertFalse(room.isEliminated(alice));
        assertFalse(room.isEliminated(carol));
        assertFalse(room.isEliminated(dave));
        assertEq(room.activePlayers(), 3);
    }

    function test_slice_paysSlicerIncentive() public {
        _setupSliceScenario();

        uint256 expectedIncentive = _slicerReservePerPlayer();
        address usdc = HLConstants.usdc();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        assertEq(IERC20(usdc).balanceOf(keeper), expectedIncentive);
    }

    function test_slice_decrementsSlicerReserve() public {
        _setupSliceScenario();

        uint256 reserveBefore = room.slicerReserve();
        uint256 expectedIncentive = _slicerReservePerPlayer();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        assertEq(room.slicerReserve(), reserveBefore - expectedIncentive);
    }

    function test_slice_prizePoolUnchanged() public {
        _setupSliceScenario();

        uint256 prizePoolBefore = room.prizePool();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        assertEq(room.prizePool(), prizePoolBefore);
    }

    function test_slice_resetsCooldown() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        assertEq(room.lastSliceBlock(), block.number);
    }

    function test_slice_emitsEvent() public {
        _setupSliceScenario();

        uint256 expectedIncentive = _slicerReservePerPlayer();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        vm.prank(keeper);
        vm.expectEmit(true, true, false, true);
        emit IGameRoom.Sliced(bob, keeper, expectedIncentive, 3);
        room.slice(assets);
    }

    function test_slice_revertsIfNotActive() public {
        _joinPlayer(alice);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.expectRevert(IGameRoom.NotActive.selector);
        room.slice(assets);
    }

    function test_slice_revertsIfCooldownNotElapsed() public {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.expectRevert(IGameRoom.CooldownNotElapsed.selector);
        room.slice(assets);
    }

    function test_slice_revertsAfterSliceBeforeCooldown() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(carol, 50e6); // carol now lowest
        _mockPlayerScore(dave, 200e6);

        vm.prank(keeper);
        vm.expectRevert(IGameRoom.CooldownNotElapsed.selector);
        room.slice(assets);
    }

    function test_slice_secondSliceAfterCooldown() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(alice, 80e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);

        vm.prank(keeper);
        room.slice(assets);

        assertTrue(room.isEliminated(alice));
        assertEq(room.activePlayers(), 2);
    }

    function test_slice_skipsEliminatedPlayers() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(keeper);
        room.slice(assets);

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(carol, 50e6);
        _mockPlayerScore(dave, 200e6);

        vm.prank(keeper);
        room.slice(assets);

        assertTrue(room.isEliminated(carol));
        assertFalse(room.isEliminated(alice));
    }

    function test_finalSlice_paysEntireReserve() public {
        HarnessGameRoom room2 = new HarnessGameRoom();
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: PRIZE_POOL_SHARE,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: SLICER_INCENTIVE,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: 2,
            maxPlayers: 2,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });
        room2.initialize(config, address(proxyImpl));

        address usdc = HLConstants.usdc();
        deal(usdc, alice, ENTRY_BET);
        vm.prank(alice);
        IERC20(usdc).approve(address(room2), ENTRY_BET);
        vm.prank(alice);
        room2.join();

        deal(usdc, bob, ENTRY_BET);
        vm.prank(bob);
        IERC20(usdc).approve(address(room2), ENTRY_BET);
        vm.prank(bob);
        room2.join();

        uint256 totalReserve = room2.slicerReserve();
        assertGt(totalReserve, 0);

        _mockPlayerScore2(room2, alice, 100e6);
        _mockPlayerScore2(room2, bob, 50e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper);
        room2.slice(assets);

        assertEq(IERC20(usdc).balanceOf(keeper), totalReserve);
        assertEq(room2.slicerReserve(), 0);
    }

    function test_finalSlice_transitionsToRevokingAgents() public {
        HarnessGameRoom room2 = new HarnessGameRoom();
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: PRIZE_POOL_SHARE,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: SLICER_INCENTIVE,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: 2,
            maxPlayers: 2,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });
        room2.initialize(config, address(proxyImpl));

        address usdc = HLConstants.usdc();
        deal(usdc, alice, ENTRY_BET);
        vm.prank(alice);
        IERC20(usdc).approve(address(room2), ENTRY_BET);
        vm.prank(alice);
        room2.join();

        deal(usdc, bob, ENTRY_BET);
        vm.prank(bob);
        IERC20(usdc).approve(address(room2), ENTRY_BET);
        vm.prank(bob);
        room2.join();

        _mockPlayerScore2(room2, alice, 100e6);
        _mockPlayerScore2(room2, bob, 50e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper);
        room2.slice(assets);

        assertEq(uint256(room2.state()), uint256(IGameRoom.RoundState.REVOKING_AGENTS));
        assertEq(room2.activePlayers(), 1);
        assertEq(room2.winner(), alice);
    }

    function test_finalSlice_drainsFullReserve_4players() public {
        _setupSliceScenario();

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        address usdc = HLConstants.usdc();

        uint256 perSliceIncentive = _slicerReservePerPlayer();
        uint256 totalReserve = room.slicerReserve();
        uint256 keeperTotal;

        vm.prank(keeper);
        room.slice(assets);
        keeperTotal += perSliceIncentive;

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(alice, 30e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);
        vm.prank(keeper);
        room.slice(assets);
        keeperTotal += perSliceIncentive;

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(carol, 100e6);
        _mockPlayerScore(dave, 200e6);
        vm.prank(keeper);
        room.slice(assets);
        uint256 finalIncentive = totalReserve - 2 * perSliceIncentive;
        keeperTotal += finalIncentive;

        assertEq(IERC20(usdc).balanceOf(keeper), keeperTotal);
        assertEq(room.slicerReserve(), 0);
        assertEq(keeperTotal, totalReserve);
    }

    function testFuzz_slice_cooldownTiming(uint256 blocksAfterStart) public {
        blocksAfterStart = bound(blocksAfterStart, 0, SLICE_COOLDOWN * 3);

        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);

        vm.roll(block.number + blocksAfterStart);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        if (blocksAfterStart < SLICE_COOLDOWN) {
            vm.expectRevert(IGameRoom.CooldownNotElapsed.selector);
            vm.prank(keeper);
            room.slice(assets);
        } else {
            vm.prank(keeper);
            room.slice(assets);
            assertTrue(room.isEliminated(bob));
        }
    }
}
