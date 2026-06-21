// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {HarnessGameRoom} from "./mocks/HarnessGameRoom.sol";

abstract contract GameRoomBaseTestBase is MockHyperCore {
    HarnessGameRoom room;
    PlayerProxy proxyImpl;

    uint256 constant ENTRY_BET = 100e6; // 100 USDC
    uint256 constant PRIZE_POOL_SHARE = 2000; // 20% in bps
    uint256 constant SLICER_INCENTIVE = 500; // 5% in bps
    uint8 constant MIN_PLAYERS = 2;
    uint8 constant MAX_PLAYERS = 4;
    uint256 constant JOIN_WINDOW = 50; // blocks
    uint256 constant SLICE_COOLDOWN = 100; // blocks
    uint256 constant AGENT_REVOCATION_DELAY = 5; // mirrors GameRoomBase.AGENT_REVOCATION_DELAY

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();

        _deployMockCoreDepositWallet();
        _mockTokenInfoForUsdc();

        proxyImpl = new PlayerProxy();
        room = new HarnessGameRoom();

        uint32[] memory allowedAssets = new uint32[](1);
        allowedAssets[0] = BTC_PERP;

        IGameRoom.GameConfig memory config = IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: PRIZE_POOL_SHARE,
            sliceCooldown: SLICE_COOLDOWN,
            slicerIncentive: SLICER_INCENTIVE,
            maxRoundDuration: 1000,
            joinWindow: JOIN_WINDOW,
            minPlayers: MIN_PLAYERS,
            maxPlayers: MAX_PLAYERS,
            allowedAssets: allowedAssets,
            builderAddress: address(0),
            builderFeeRate: 0
        });

        room.initialize(config, address(proxyImpl));
    }

    function _deployMockCoreDepositWallet() internal {
        address walletAddr = HLConstants.coreDepositWallet();
        vm.etch(walletAddr, address(new MockCoreDepositWallet()).code);
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

    function _joinPlayer(address player) internal {
        address usdc = HLConstants.usdc();
        deal(usdc, player, ENTRY_BET);
        vm.startPrank(player);
        IERC20(usdc).approve(address(room), ENTRY_BET);
        room.join();
        vm.stopPrank();
    }

    function _fillAndStart() internal {
        _joinPlayer(alice);
        _joinPlayer(bob);
        _joinPlayer(carol);
        _joinPlayer(dave);
    }

    function _mockPlayerScore(address player, int256 score) internal {
        room.forceScore(player, score);
    }

    function _setupSliceScenario() internal {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);
        vm.roll(block.number + SLICE_COOLDOWN);
    }

    function _prizePoolPerPlayer() internal pure returns (uint256) {
        return (ENTRY_BET * PRIZE_POOL_SHARE) / 10_000;
    }

    function _slicerReservePerPlayer() internal pure returns (uint256) {
        return (ENTRY_BET * SLICER_INCENTIVE) / 10_000;
    }

    function _tradingBalPerPlayer() internal pure returns (uint256) {
        return ENTRY_BET - _prizePoolPerPlayer() - _slicerReservePerPlayer();
    }

    function _sliceToLastMan() internal {
        _fillAndStart();
        _mockPlayerScore(alice, 100e6);
        _mockPlayerScore(bob, 50e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);

        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        vm.roll(block.number + SLICE_COOLDOWN);
        vm.prank(keeper);
        room.slice(assets);

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(alice, 30e6);
        _mockPlayerScore(carol, 150e6);
        _mockPlayerScore(dave, 200e6);
        vm.prank(keeper);
        room.slice(assets);

        vm.roll(block.number + SLICE_COOLDOWN);
        _mockPlayerScore(carol, 100e6);
        _mockPlayerScore(dave, 200e6);
        vm.prank(keeper);
        room.slice(assets);

        _advancePastRevocation();
    }

    function _advancePastRevocation() internal {
        vm.roll(block.number + AGENT_REVOCATION_DELAY);
        room.advanceSettlement();
    }

    function _mockPositionClosed(address proxy, uint32 asset) internal {
        PrecompileLib.Position memory pos;
        vm.mockCall(HLConstants.POSITION_PRECOMPILE_ADDRESS, abi.encode(proxy, uint16(asset)), abi.encode(pos));
    }

    function _mockPositionOpen(address proxy, uint32 asset, int64 szi) internal {
        PrecompileLib.Position memory pos =
            PrecompileLib.Position({szi: szi, entryNtl: 1000, isolatedRawUsd: 0, leverage: 10, isIsolated: false});
        vm.mockCall(HLConstants.POSITION_PRECOMPILE_ADDRESS, abi.encode(proxy, uint16(asset)), abi.encode(pos));
    }

    function _mockWithdrawableZero(address proxy) internal {
        vm.mockCall(
            HLConstants.WITHDRAWABLE_PRECOMPILE_ADDRESS,
            abi.encode(proxy),
            abi.encode(PrecompileLib.Withdrawable({withdrawable: 0}))
        );
    }

    function _mockSpotBalanceZero(address proxy) internal {
        vm.mockCall(
            HLConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS,
            abi.encode(proxy, uint64(HLConstants.USDC_TOKEN_INDEX)),
            abi.encode(PrecompileLib.SpotBalance({total: 0, hold: 0, entryNtl: 0}))
        );
    }

    function _mockAllPositionsClosed() internal {
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            _mockPositionClosed(room.playerProxy(players[i]), BTC_PERP);
        }
    }

    function _mockAllFundsWithdrawn() internal {
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            address proxy = room.playerProxy(players[i]);
            _mockWithdrawableZero(proxy);
            _mockSpotBalanceZero(proxy);
        }
    }

    function _setSpotDustForAll(uint64 dust) internal {
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            address proxy = room.playerProxy(players[i]);
            hyperCore.forcePerpBalance(proxy, 0);
            hyperCore.forceSpotBalance(proxy, HLConstants.USDC_TOKEN_INDEX, dust);
        }
    }

    function _mockPlayerScore2(HarnessGameRoom room_, address player, int256 score) internal {
        room_.forceScore(player, score);
    }
}
