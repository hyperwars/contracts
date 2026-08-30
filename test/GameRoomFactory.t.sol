// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GameRoomFactory} from "../src/GameRoomFactory.sol";
import {GameMaster} from "../src/GameMaster.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

contract GameRoomFactoryTest is MockHyperCore {
    GameRoomFactory factory;
    GameMaster master;
    DefaultGameRoom roomImpl;
    PlayerProxy proxyImpl;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");

    uint256 constant MAX_PLAYERS = 10;
    uint256 constant MAX_ASSETS = 5;
    uint256 constant MAX_ROUND_DURATION = 3600;

    function setUp() public override {
        super.setUp();

        address walletAddr = HLConstants.coreDepositWallet();
        vm.etch(walletAddr, address(new MockCoreDepositWallet()).code);

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

        proxyImpl = new PlayerProxy();
        roomImpl = new DefaultGameRoom();
        factory = new GameRoomFactory(address(roomImpl), address(0), MAX_PLAYERS, MAX_ASSETS, MAX_ROUND_DURATION);

        GameMaster impl = new GameMaster();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(GameMaster.initialize, (admin, treasury, address(proxyImpl), uint256(0)))
        );
        master = GameMaster(address(proxy));

        vm.prank(admin);
        master.registerFactory(address(factory));
    }

    function _defaultConfig() internal pure returns (IGameRoom.GameConfig memory) {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        return IGameRoom.GameConfig({
            entryBet: 100e6,
            maxRoundDuration: 1000,
            joinWindow: 50,
            minPlayers: 2,
            maxPlayers: 4,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });
    }

    function test_constructor_setsImmutables() public view {
        assertEq(factory.roomImplementation(), address(roomImpl));
        assertEq(factory.builderFeeRecipient(), address(0));
    }

    function test_constructor_customBuilderFeeRecipient() public {
        address custom = makeAddr("custom");
        GameRoomFactory f = new GameRoomFactory(address(roomImpl), custom, MAX_PLAYERS, MAX_ASSETS, MAX_ROUND_DURATION);
        assertEq(f.builderFeeRecipient(), custom);
    }

    function test_createRoom_deploysClone() public {
        address room = factory.createRoom(_defaultConfig(), address(proxyImpl));
        assertTrue(room != address(0));
        assertEq(uint256(DefaultGameRoom(room).state()), uint256(IGameRoom.RoundState.LOBBY));
    }

    function test_createRoom_passesConfigThrough() public {
        address room = factory.createRoom(_defaultConfig(), address(proxyImpl));

        IGameRoom.GameConfig memory config = DefaultGameRoom(room).getConfig();
        assertEq(config.entryBet, 100e6);
        assertEq(config.minPlayers, 2);
        assertEq(config.maxPlayers, 4);
    }

    function test_createRoom_passesProxyImpl() public {
        address room = factory.createRoom(_defaultConfig(), address(proxyImpl));
        assertEq(DefaultGameRoom(room).proxyImplementation(), address(proxyImpl));
    }

    function test_createRoom_cloneIsFunctional() public {
        DefaultGameRoom room = DefaultGameRoom(master.createRoom(address(factory), _defaultConfig()));

        address alice = makeAddr("alice");
        address proxy = room.predictProxy(alice);
        hyperCore.forceAccountActivation(proxy);
        hyperCore.forceSpotBalance(proxy, HLConstants.USDC_TOKEN_INDEX, uint64(100e6));
        room.register(alice);

        assertEq(room.getPlayerCount(), 1);
        assertTrue(room.hasJoined(alice));
    }

    function test_createRoom_multipleClones() public {
        address room1 = factory.createRoom(_defaultConfig(), address(proxyImpl));
        address room2 = factory.createRoom(_defaultConfig(), address(proxyImpl));
        assertTrue(room1 != room2);
    }

    function test_constructor_setsCapImmutables() public view {
        assertEq(factory.maxPlayers(), MAX_PLAYERS);
        assertEq(factory.maxAssets(), MAX_ASSETS);
        assertEq(factory.maxRoundDuration(), MAX_ROUND_DURATION);
    }

    function test_createRoom_revertsAboveMaxPlayers() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.maxPlayers = uint8(MAX_PLAYERS + 1);
        vm.expectRevert(GameRoomFactory.MaxPlayersExceeded.selector);
        factory.createRoom(config, address(proxyImpl));
    }

    function test_createRoom_revertsAboveMaxAssets() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.allowedAssets = _assets(MAX_ASSETS + 1);
        vm.expectRevert(GameRoomFactory.MaxAssetsExceeded.selector);
        factory.createRoom(config, address(proxyImpl));
    }

    function test_createRoom_revertsAboveMaxRoundDuration() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.maxRoundDuration = MAX_ROUND_DURATION + 1;
        vm.expectRevert(GameRoomFactory.MaxRoundDurationExceeded.selector);
        factory.createRoom(config, address(proxyImpl));
    }

    function test_createRoom_acceptsAtCapLimit() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.maxPlayers = uint8(MAX_PLAYERS);
        config.maxRoundDuration = MAX_ROUND_DURATION;
        config.allowedAssets = _assets(MAX_ASSETS);
        address room = factory.createRoom(config, address(proxyImpl));
        assertTrue(room != address(0));
    }

    function test_createRoom_revertsIneligibleBuilder() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.builderAddress = makeAddr("builder");
        config.builderFeeRate = 5;
        hyperCore.forcePerpBalance(config.builderAddress, 100e6 - 1);
        vm.expectRevert(GameRoomFactory.BuilderNotEligible.selector);
        factory.createRoom(config, address(proxyImpl));
    }

    function test_createRoom_revertsZeroBuilderWithFee() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.builderFeeRate = 5;
        vm.expectRevert(GameRoomFactory.BuilderNotEligible.selector);
        factory.createRoom(config, address(proxyImpl));
    }

    function test_createRoom_acceptsEligibleBuilder() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.builderAddress = makeAddr("builder");
        config.builderFeeRate = 5;
        hyperCore.forcePerpBalance(config.builderAddress, 100e6);
        address room = factory.createRoom(config, address(proxyImpl));
        assertTrue(room != address(0));
    }

    function test_createRoom_skipsBuilderCheckWithoutFee() public {
        IGameRoom.GameConfig memory config = _defaultConfig();
        config.builderAddress = makeAddr("builder");
        config.builderFeeRate = 0;
        address room = factory.createRoom(config, address(proxyImpl));
        assertTrue(room != address(0));
    }

    function _assets(uint256 n) internal pure returns (uint32[] memory assets) {
        assets = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            assets[i] = uint32(i);
        }
    }
}
