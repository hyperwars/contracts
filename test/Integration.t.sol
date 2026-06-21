// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GameMaster} from "../src/GameMaster.sol";
import {GameRoomFactory} from "../src/GameRoomFactory.sol";
import {GameRoomBase} from "../src/GameRoomBase.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {HarnessGameRoom} from "./mocks/HarnessGameRoom.sol";

// Demonstrates a custom room that inverts accountValue as its scoring metric.
contract ScoreFlipRoom is GameRoomBase {
    function getPlayerScore(address player) public view override returns (int256) {
        return -int256(PlayerProxy(payable(playerProxy[player])).getMarginSummary().accountValue);
    }
}

contract IntegrationTest is MockHyperCore {
    GameMaster master;
    GameRoomFactory factory;
    HarnessGameRoom roomImpl;
    PlayerProxy proxyImpl;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address keeper1 = makeAddr("keeper1");
    address keeper2 = makeAddr("keeper2");

    uint256 constant ENTRY_BET = 100e6;
    uint256 constant PRIZE_POOL_SHARE = 2000;
    uint256 constant SLICER_INCENTIVE = 500;
    uint256 constant JOIN_WINDOW = 50;
    uint256 constant SLICE_COOLDOWN = 100;
    uint256 constant MAX_ROUND_DURATION = 1000;

    function setUp() public override {
        super.setUp();

        address walletAddr = HLConstants.coreDepositWallet();
        vm.etch(walletAddr, address(new MockCoreDepositWallet()).code);
        _mockTokenInfoForUsdc();

        proxyImpl = new PlayerProxy();
        roomImpl = new HarnessGameRoom();

        GameMaster impl = new GameMaster();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(GameMaster.initialize, (admin, treasury, address(proxyImpl), uint256(0)))
        );
        master = GameMaster(address(proxy));

        factory = new GameRoomFactory(address(roomImpl), address(0), 10, 5, 3600);
        vm.prank(admin);
        master.registerFactory(address(factory));
    }

    function _mockTokenInfoForUsdc() internal {
        uint64[] memory spots = new uint64[](0);
        PrecompileLib.TokenInfo memory info = PrecompileLib.TokenInfo({
            name: "USDC",
            spots: spots,
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: HLConstants.usdc(),
            szDecimals: 6,
            weiDecimals: 6,
            evmExtraWeiDecimals: 0
        });
        vm.mockCall(
            HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS,
            abi.encode(uint64(HLConstants.USDC_TOKEN_INDEX)),
            abi.encode(info)
        );
        vm.mockCall(
            HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.USDC_TOKEN_INDEX)),
            abi.encode(info)
        );
    }

    function _defaultConfig() internal pure returns (IGameRoom.GameConfig memory) {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        return IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: PRIZE_POOL_SHARE,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: SLICER_INCENTIVE,
            maxRoundDuration: MAX_ROUND_DURATION,
            joinWindow: JOIN_WINDOW,
            minPlayers: 2,
            maxPlayers: 4,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });
    }

    function _createRoom() internal returns (HarnessGameRoom) {
        address room = master.createRoom(address(factory), _defaultConfig());
        return HarnessGameRoom(room);
    }

    function _joinPlayer(HarnessGameRoom room, address player) internal {
        address usdc = HLConstants.usdc();
        deal(usdc, player, ENTRY_BET);
        vm.startPrank(player);
        IERC20(usdc).approve(address(room), ENTRY_BET);
        room.join();
        vm.stopPrank();
    }

    function _mockScore(HarnessGameRoom room, address player, int256 score) internal {
        room.forceScore(player, score);
    }

    function _passRevocation(HarnessGameRoom room) internal {
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.REVOKING_AGENTS));
        vm.roll(block.number + 5);
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.CLOSING_POSITIONS));
    }

    function _mockAllPositionsClosed(HarnessGameRoom room) internal {
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            address proxy = room.playerProxy(players[i]);
            PrecompileLib.Position memory pos;
            vm.mockCall(HLConstants.POSITION_PRECOMPILE_ADDRESS, abi.encode(proxy, uint16(BTC_PERP)), abi.encode(pos));
        }
    }

    function _mockAllFundsWithdrawn(HarnessGameRoom room) internal {
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            address proxy = room.playerProxy(players[i]);
            vm.mockCall(
                HLConstants.WITHDRAWABLE_PRECOMPILE_ADDRESS,
                abi.encode(proxy),
                abi.encode(PrecompileLib.Withdrawable({withdrawable: 0}))
            );
            vm.mockCall(
                HLConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS,
                abi.encode(proxy, uint64(HLConstants.USDC_TOKEN_INDEX)),
                abi.encode(PrecompileLib.SpotBalance({total: 0, hold: 0, entryNtl: 0}))
            );
        }
    }

    function _dealTradingBalanceBack(HarnessGameRoom room) internal {
        uint256 tradingBal =
            ENTRY_BET - (ENTRY_BET * PRIZE_POOL_SHARE) / 10_000 - (ENTRY_BET * SLICER_INCENTIVE) / 10_000;
        address usdc = HLConstants.usdc();
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            deal(usdc, room.playerProxy(players[i]), tradingBal);
        }
    }

    function test_happyPath_lastManStanding() public {
        HarnessGameRoom room = _createRoom();

        assertTrue(master.isRoom(address(room)));

        _joinPlayer(room, alice);
        _joinPlayer(room, bob);
        _joinPlayer(room, carol);
        _joinPlayer(room, dave);

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.ACTIVE));
        assertEq(room.activePlayers(), 4);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        _mockScore(room, alice, 200e6);
        _mockScore(room, bob, 50e6);
        _mockScore(room, carol, 150e6);
        _mockScore(room, dave, 100e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper1);
        room.slice(assets);
        assertTrue(room.isEliminated(bob));
        assertEq(room.activePlayers(), 3);

        _mockScore(room, alice, 200e6);
        _mockScore(room, carol, 150e6);
        _mockScore(room, dave, 30e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper1);
        room.slice(assets);
        assertTrue(room.isEliminated(dave));
        assertEq(room.activePlayers(), 2);

        _mockScore(room, alice, 200e6);
        _mockScore(room, carol, 100e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper1);
        room.slice(assets);
        assertTrue(room.isEliminated(carol));
        assertEq(room.activePlayers(), 1);
        assertEq(room.winner(), alice);
        _passRevocation(room);

        _mockAllPositionsClosed(room);
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.WITHDRAWING));

        _mockAllFundsWithdrawn(room);
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.DISTRIBUTING));

        _dealTradingBalanceBack(room);
        room.advanceSettlement();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));

        assertGt(IERC20(HLConstants.usdc()).balanceOf(alice), 0);
        assertEq(IERC20(HLConstants.usdc()).balanceOf(address(room)), 0);
    }

    function test_timeLimit_highestEquityWins() public {
        HarnessGameRoom room = _createRoom();

        _joinPlayer(room, alice);
        _joinPlayer(room, bob);
        _joinPlayer(room, carol);
        _joinPlayer(room, dave);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        _mockScore(room, alice, 100e6);
        _mockScore(room, bob, 50e6);
        _mockScore(room, carol, 150e6);
        _mockScore(room, dave, 200e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper1);
        room.slice(assets);
        assertTrue(room.isEliminated(bob));

        _mockScore(room, alice, 100e6);
        _mockScore(room, carol, 300e6);
        _mockScore(room, dave, 200e6);

        vm.roll(block.number + MAX_ROUND_DURATION);
        room.settleByTimeLimit();

        assertEq(room.winner(), carol);
        _passRevocation(room);

        _mockAllPositionsClosed(room);
        room.advanceSettlement();
        _mockAllFundsWithdrawn(room);
        room.advanceSettlement();
        _dealTradingBalanceBack(room);
        room.advanceSettlement();

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));
        assertGt(IERC20(HLConstants.usdc()).balanceOf(carol), 0);
    }

    function test_lobbyCancellation_fullRefunds() public {
        HarnessGameRoom room = _createRoom();

        _joinPlayer(room, alice);

        vm.roll(block.number + JOIN_WINDOW);
        room.cancel();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.CANCELLED));

        address usdc = HLConstants.usdc();
        uint256 balBefore = IERC20(usdc).balanceOf(alice);
        vm.prank(alice);
        room.claimRefund();
        assertEq(IERC20(usdc).balanceOf(alice), balBefore + ENTRY_BET);
    }

    function test_customRoom_scoreFlip() public {
        ScoreFlipRoom flipImpl = new ScoreFlipRoom();
        GameRoomFactory flipFactory = new GameRoomFactory(address(flipImpl), address(0), 10, 5, 3600);
        vm.prank(admin);
        master.registerFactory(address(flipFactory));

        address roomAddr = master.createRoom(address(flipFactory), _defaultConfig());
        ScoreFlipRoom room = ScoreFlipRoom(roomAddr);

        address usdc = HLConstants.usdc();
        deal(usdc, alice, ENTRY_BET);
        vm.startPrank(alice);
        IERC20(usdc).approve(address(room), ENTRY_BET);
        room.join();
        vm.stopPrank();

        deal(usdc, bob, ENTRY_BET);
        vm.startPrank(bob);
        IERC20(usdc).approve(address(room), ENTRY_BET);
        room.join();
        vm.stopPrank();

        vm.roll(block.number + JOIN_WINDOW);
        room.startRound();

        // Alice has higher equity — in ScoreFlipRoom she gets sliced first
        address aliceProxy = room.playerProxy(alice);
        address bobProxy = room.playerProxy(bob);
        PrecompileLib.AccountMarginSummary memory highSummary =
            PrecompileLib.AccountMarginSummary({accountValue: 200e6, marginUsed: 0, ntlPos: 0, rawUsd: 0});
        PrecompileLib.AccountMarginSummary memory lowSummary =
            PrecompileLib.AccountMarginSummary({accountValue: 50e6, marginUsed: 0, ntlPos: 0, rawUsd: 0});
        vm.mockCall(
            HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.DEFAULT_PERP_DEX), aliceProxy),
            abi.encode(highSummary)
        );
        vm.mockCall(
            HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.DEFAULT_PERP_DEX), bobProxy),
            abi.encode(lowSummary)
        );

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper1);
        room.slice(assets);

        // Highest equity (alice) gets sliced, not lowest (bob)
        assertTrue(room.isEliminated(alice));
        assertFalse(room.isEliminated(bob));
        assertEq(room.winner(), bob);
    }

    function test_fundInvariant_noLeaks() public {
        HarnessGameRoom room = _createRoom();
        address usdc = HLConstants.usdc();

        uint256 totalDeposited = ENTRY_BET * 4;

        _joinPlayer(room, alice);
        _joinPlayer(room, bob);
        _joinPlayer(room, carol);
        _joinPlayer(room, dave);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        _mockScore(room, alice, 200e6);
        _mockScore(room, bob, 50e6);
        _mockScore(room, carol, 150e6);
        _mockScore(room, dave, 100e6);

        uint256 slicerTotal;

        vm.roll(block.number + SLICE_COOLDOWN);
        uint256 k1Before = IERC20(usdc).balanceOf(keeper1);
        vm.prank(keeper1);
        room.slice(assets);
        slicerTotal += IERC20(usdc).balanceOf(keeper1) - k1Before;

        _mockScore(room, alice, 200e6);
        _mockScore(room, carol, 150e6);
        _mockScore(room, dave, 30e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        k1Before = IERC20(usdc).balanceOf(keeper1);
        vm.prank(keeper1);
        room.slice(assets);
        slicerTotal += IERC20(usdc).balanceOf(keeper1) - k1Before;

        _mockScore(room, alice, 200e6);
        _mockScore(room, carol, 100e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        k1Before = IERC20(usdc).balanceOf(keeper1);
        vm.prank(keeper1);
        room.slice(assets);
        slicerTotal += IERC20(usdc).balanceOf(keeper1) - k1Before;

        _passRevocation(room);
        _mockAllPositionsClosed(room);
        room.advanceSettlement();
        _mockAllFundsWithdrawn(room);
        room.advanceSettlement();
        _dealTradingBalanceBack(room);
        room.advanceSettlement();

        uint256 winnerPayout = IERC20(usdc).balanceOf(alice);

        assertEq(winnerPayout + slicerTotal, totalDeposited);
        assertEq(IERC20(usdc).balanceOf(address(room)), 0);
        assertEq(room.slicerReserve(), 0);
    }

    function test_keeperFlow_differentKeepers() public {
        HarnessGameRoom room = _createRoom();

        _joinPlayer(room, alice);
        _joinPlayer(room, bob);
        _joinPlayer(room, carol);
        _joinPlayer(room, dave);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        _mockScore(room, alice, 200e6);
        _mockScore(room, bob, 50e6);
        _mockScore(room, carol, 150e6);
        _mockScore(room, dave, 100e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper1);
        room.slice(assets);

        _mockScore(room, alice, 200e6);
        _mockScore(room, carol, 150e6);
        _mockScore(room, dave, 30e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper2);
        room.slice(assets);

        _mockScore(room, alice, 200e6);
        _mockScore(room, carol, 100e6);

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper1);
        room.slice(assets);

        // Different keepers advance settlement phases
        _passRevocation(room);
        _mockAllPositionsClosed(room);
        vm.prank(keeper1);
        room.advanceSettlement();

        _mockAllFundsWithdrawn(room);
        vm.prank(keeper2);
        room.advanceSettlement();

        _dealTradingBalanceBack(room);
        vm.prank(keeper1);
        room.advanceSettlement();

        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));
        assertGt(IERC20(HLConstants.usdc()).balanceOf(alice), 0);
    }
}
