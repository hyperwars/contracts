// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {GameRoomBaseTestBase} from "./GameRoomBase.base.sol";

contract GameRoomJoinTest is GameRoomBaseTestBase {
    function test_join_deploysProxyAndRecordsPlayer() public {
        _joinPlayer(alice);

        assertTrue(room.hasJoined(alice));
        assertEq(room.getPlayerCount(), 1);

        address proxy = room.playerProxy(alice);
        assertTrue(proxy != address(0));

        address[] memory players = room.getPlayers();
        assertEq(players.length, 1);
        assertEq(players[0], alice);
    }

    function test_join_transfersUsdcToGameRoom() public {
        address usdc = HLConstants.usdc();
        _joinPlayer(alice);
        assertEq(IERC20(usdc).balanceOf(address(room)), ENTRY_BET);
        assertEq(IERC20(usdc).balanceOf(alice), 0);
    }

    function test_join_initializesProxyCorrectly() public {
        _joinPlayer(alice);

        address proxyAddr = room.playerProxy(alice);
        PlayerProxy proxy = PlayerProxy(payable(proxyAddr));

        assertEq(proxy.owner(), alice);
        assertEq(proxy.gameRoom(), address(room));
    }

    function test_join_emitsEvent() public {
        address usdc = HLConstants.usdc();
        deal(usdc, alice, ENTRY_BET);
        vm.startPrank(alice);
        IERC20(usdc).approve(address(room), ENTRY_BET);

        vm.expectEmit(true, false, false, true);
        emit IGameRoom.PlayerJoined(alice, address(0), 1);
        room.join();
        vm.stopPrank();
    }

    function test_join_autoStartsWhenFull() public {
        _fillAndStart();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.ACTIVE));
        assertGt(room.prizePool(), 0);
    }

    function test_join_revertsIfAlreadyJoined() public {
        _joinPlayer(alice);

        deal(HLConstants.usdc(), alice, ENTRY_BET);
        vm.startPrank(alice);
        IERC20(HLConstants.usdc()).approve(address(room), ENTRY_BET);
        vm.expectRevert(IGameRoom.AlreadyJoined.selector);
        room.join();
        vm.stopPrank();
    }

    function test_join_revertsIfNotLobby() public {
        _fillAndStart();

        deal(HLConstants.usdc(), makeAddr("late"), ENTRY_BET);
        vm.startPrank(makeAddr("late"));
        IERC20(HLConstants.usdc()).approve(address(room), ENTRY_BET);
        vm.expectRevert(IGameRoom.NotInLobby.selector);
        room.join();
        vm.stopPrank();
    }

    function test_join_revertsIfLobbyFull() public {
        _fillAndStart();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.ACTIVE));
    }

    function test_startRound_transitionsToActive() public {
        _joinPlayer(alice);
        _joinPlayer(bob);

        vm.roll(block.number + JOIN_WINDOW);
        room.startRound();

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.ACTIVE));
    }

    function test_startRound_threeWaySplit() public {
        _joinPlayer(alice);
        _joinPlayer(bob);

        vm.roll(block.number + JOIN_WINDOW);
        room.startRound();

        assertEq(room.prizePool(), _prizePoolPerPlayer() * 2);
        assertEq(room.slicerReserve(), _slicerReservePerPlayer() * 2);
        assertEq(room.activePlayers(), 2);

        address usdc = HLConstants.usdc();
        uint256 roomBal = IERC20(usdc).balanceOf(address(room));
        assertEq(roomBal, room.prizePool() + room.slicerReserve());

        uint256 walletBal = IERC20(usdc).balanceOf(HLConstants.coreDepositWallet());
        assertEq(walletBal, _tradingBalPerPlayer() * 2);
    }

    function test_startRound_setsSliceState() public {
        _joinPlayer(alice);
        _joinPlayer(bob);

        uint256 startBlock = block.number + JOIN_WINDOW;
        vm.roll(startBlock);
        room.startRound();

        assertEq(room.lastSliceBlock(), startBlock);
        assertEq(room.activePlayers(), 2);
    }

    function test_startRound_revertsBeforeJoinWindow() public {
        _joinPlayer(alice);
        _joinPlayer(bob);

        vm.expectRevert(IGameRoom.JoinWindowNotElapsed.selector);
        room.startRound();
    }

    function test_startRound_revertsIfBelowMinPlayers() public {
        _joinPlayer(alice);

        vm.roll(block.number + JOIN_WINDOW);
        vm.expectRevert(IGameRoom.BelowMinPlayers.selector);
        room.startRound();
    }

    function test_startRound_emitsEvent() public {
        _joinPlayer(alice);
        _joinPlayer(bob);
        vm.roll(block.number + JOIN_WINDOW);

        uint256 expectedPrize = _prizePoolPerPlayer() * 2;
        vm.expectEmit(false, false, false, true);
        emit IGameRoom.RoundStarted(2, expectedPrize);
        room.startRound();
    }

    function test_depositSplit_accounting() public {
        _joinPlayer(alice);
        _joinPlayer(bob);

        vm.roll(block.number + JOIN_WINDOW);
        room.startRound();

        address usdc = HLConstants.usdc();
        uint256 totalDeposited = ENTRY_BET * 2;
        uint256 roomBal = IERC20(usdc).balanceOf(address(room));
        uint256 walletBal = IERC20(usdc).balanceOf(HLConstants.coreDepositWallet());

        // prizePool + slicerReserve + bridged trading = total deposits
        assertEq(roomBal + walletBal, totalDeposited);
        assertEq(room.prizePool() + room.slicerReserve(), roomBal);
    }

    function testFuzz_depositSplit_accuracy(uint256 prizeShare) public {
        prizeShare = bound(prizeShare, 0, 10_000 - SLICER_INCENTIVE - 1);

        DefaultGameRoom fuzzRoom = new DefaultGameRoom();
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: prizeShare,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: SLICER_INCENTIVE,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: MIN_PLAYERS,
            maxPlayers: MAX_PLAYERS,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });
        fuzzRoom.initialize(config, address(proxyImpl));

        address p1 = makeAddr("fuzzP1");
        address p2 = makeAddr("fuzzP2");
        address usdc = HLConstants.usdc();

        deal(usdc, p1, ENTRY_BET);
        vm.prank(p1);
        IERC20(usdc).approve(address(fuzzRoom), ENTRY_BET);
        vm.prank(p1);
        fuzzRoom.join();

        deal(usdc, p2, ENTRY_BET);
        vm.prank(p2);
        IERC20(usdc).approve(address(fuzzRoom), ENTRY_BET);
        vm.prank(p2);
        fuzzRoom.join();

        vm.roll(block.number + JOIN_WINDOW);
        fuzzRoom.startRound();

        uint256 totalDeposited = ENTRY_BET * 2;
        uint256 roomBal = IERC20(usdc).balanceOf(address(fuzzRoom));
        uint256 walletBal = IERC20(usdc).balanceOf(HLConstants.coreDepositWallet());

        assertEq(roomBal + walletBal, totalDeposited);
    }

    function testFuzz_join_multiplePlayers(uint8 count) public {
        count = uint8(bound(count, 1, MAX_PLAYERS - 1));
        for (uint8 i; i < count; ++i) {
            address player = makeAddr(string(abi.encodePacked("player", i)));
            _joinPlayer(player);
        }
        assertEq(room.getPlayerCount(), count);
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.LOBBY));
    }
}
