// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {GameMaster} from "../src/GameMaster.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {IGameRoomFactory} from "../src/interfaces/IGameRoomFactory.sol";
import {MockGameRoomFactory} from "./mocks/MockGameRoomFactory.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

contract GameMasterTest is MockHyperCore {
    GameMaster master;
    GameMaster impl;
    MockGameRoomFactory factory;
    PlayerProxy proxyImpl;
    DefaultGameRoom roomImpl;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address attacker = makeAddr("attacker");

    uint256 constant MIN_TRADING_BALANCE = 2_000_000;

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

        impl = new GameMaster();
        bytes memory initData =
            abi.encodeCall(GameMaster.initialize, (admin, treasury, address(proxyImpl), MIN_TRADING_BALANCE));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        master = GameMaster(address(proxy));

        factory = new MockGameRoomFactory(address(roomImpl), address(0));

        vm.prank(admin);
        master.registerFactory(address(factory));
    }

    function _defaultConfig() internal view returns (IGameRoom.GameConfig memory) {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        return IGameRoom.GameConfig({
            entryBet: 100e6,
            prizePoolShare: 2000,
            sliceCooldown: 100,
            slicerIncentive: 500,
            maxRoundDuration: 1000,
            joinWindow: 50,
            minPlayers: 2,
            maxPlayers: 4,
            allowedAssets: assets,
            builderAddress: treasury,
            builderFeeRate: 5
        });
    }

    function test_initialize_setsState() public view {
        assertEq(master.owner(), admin);
        assertEq(master.protocolTreasury(), treasury);
        assertEq(master.userProxyImplementation(), address(proxyImpl));
        assertEq(master.minTradingBalance(), MIN_TRADING_BALANCE);
    }

    function test_initialize_revertsOnDoubleInit() public {
        vm.expectRevert();
        master.initialize(admin, treasury, address(proxyImpl), MIN_TRADING_BALANCE);
    }

    function test_initialize_revertsZeroOwner() public {
        GameMaster m = new GameMaster();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(
            address(m),
            abi.encodeCall(GameMaster.initialize, (address(0), treasury, address(proxyImpl), MIN_TRADING_BALANCE))
        );
    }

    function test_initialize_revertsZeroTreasury() public {
        GameMaster m = new GameMaster();
        vm.expectRevert(GameMaster.ZeroAddress.selector);
        new ERC1967Proxy(
            address(m),
            abi.encodeCall(GameMaster.initialize, (admin, address(0), address(proxyImpl), MIN_TRADING_BALANCE))
        );
    }

    function test_initialize_revertsZeroProxyImpl() public {
        GameMaster m = new GameMaster();
        vm.expectRevert(GameMaster.ZeroAddress.selector);
        new ERC1967Proxy(
            address(m), abi.encodeCall(GameMaster.initialize, (admin, treasury, address(0), MIN_TRADING_BALANCE))
        );
    }

    function test_registerFactory() public {
        address f2 = makeAddr("factory2");
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit GameMaster.FactoryRegistered(f2);
        master.registerFactory(f2);
        assertTrue(master.isFactory(f2));
    }

    function test_registerFactory_revertsNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        master.registerFactory(makeAddr("f"));
    }

    function test_registerFactory_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(GameMaster.ZeroAddress.selector);
        master.registerFactory(address(0));
    }

    function test_deregisterFactory() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit GameMaster.FactoryDeregistered(address(factory));
        master.deregisterFactory(address(factory));
        assertFalse(master.isFactory(address(factory)));
    }

    function test_deregisterFactory_revertsNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        master.deregisterFactory(address(factory));
    }

    function test_createRoom_succeeds() public {
        vm.expectEmit(false, true, true, false);
        emit GameMaster.RoomCreated(address(0), address(factory), address(this));
        address room = master.createRoom(address(factory), _defaultConfig());

        assertTrue(master.isRoom(room));
        assertEq(master.roomFactory(room), address(factory));
    }

    function test_createRoom_passesProxyImpl() public {
        address room = master.createRoom(address(factory), _defaultConfig());
        assertEq(DefaultGameRoom(room).proxyImplementation(), address(proxyImpl));
    }

    function test_createRoom_overridesBuilderAddress() public {
        IGameRoom.GameConfig memory cfg = _defaultConfig();
        cfg.builderAddress = makeAddr("arbitraryBuilder");

        address room = master.createRoom(address(factory), cfg);

        // factory.builderFeeRecipient() == address(0) -> falls back to protocolTreasury
        assertEq(DefaultGameRoom(room).getConfig().builderAddress, treasury);
    }

    function test_createRoom_usesFactoryBuilderFeeRecipient() public {
        address customBuilder = makeAddr("customBuilder");
        MockGameRoomFactory customFactory = new MockGameRoomFactory(address(roomImpl), customBuilder);
        vm.prank(admin);
        master.registerFactory(address(customFactory));

        address room = master.createRoom(address(customFactory), _defaultConfig());

        assertEq(DefaultGameRoom(room).getConfig().builderAddress, customBuilder);
    }

    function test_createRoom_revertsInactiveFactory() public {
        vm.expectRevert(GameMaster.FactoryNotActive.selector);
        master.createRoom(makeAddr("bogus"), _defaultConfig());
    }

    function test_createRoom_revertsDeregisteredFactory() public {
        vm.prank(admin);
        master.deregisterFactory(address(factory));

        vm.expectRevert(GameMaster.FactoryNotActive.selector);
        master.createRoom(address(factory), _defaultConfig());
    }

    function test_createRoom_revertsEntryBetTooSmall() public {
        IGameRoom.GameConfig memory cfg = _defaultConfig();
        cfg.entryBet = 1_000_000; // trading balance 750_000 < 2_000_000
        vm.expectRevert(GameMaster.EntryBetTooSmall.selector);
        master.createRoom(address(factory), cfg);
    }

    function test_createRoom_succeedsAtMinTradingBalance() public {
        IGameRoom.GameConfig memory cfg = _defaultConfig();
        cfg.entryBet = 5_000_000; // trading balance 3_750_000 >= 2_000_000
        address room = master.createRoom(address(factory), cfg);
        assertTrue(master.isRoom(room));
    }

    function test_setMinTradingBalance() public {
        vm.prank(admin);
        master.setMinTradingBalance(3_000_000);
        assertEq(master.minTradingBalance(), 3_000_000);
    }

    function test_setMinTradingBalance_revertsNonOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        master.setMinTradingBalance(3_000_000);
    }

    function test_setProtocolTreasury() public {
        address newT = makeAddr("newTreasury");
        vm.prank(admin);
        master.setProtocolTreasury(newT);
        assertEq(master.protocolTreasury(), newT);
    }

    function test_setProtocolTreasury_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(GameMaster.ZeroAddress.selector);
        master.setProtocolTreasury(address(0));
    }

    function test_setProxyImplementation() public {
        address newImpl = makeAddr("newImpl");
        vm.prank(admin);
        master.setProxyImplementation(newImpl);
        assertEq(master.userProxyImplementation(), newImpl);
    }

    function test_setProxyImplementation_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert(GameMaster.ZeroAddress.selector);
        master.setProxyImplementation(address(0));
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit OwnableUpgradeable.OwnershipTransferred(admin, newOwner);
        master.transferOwnership(newOwner);
        assertEq(master.owner(), newOwner);
    }

    function test_transferOwnership_revertsNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        master.transferOwnership(attacker);
    }

    function test_upgradeToAndCall_revertsNonOwner() public {
        GameMaster newImpl = new GameMaster();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        master.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgradeToAndCall_succeeds() public {
        GameMaster newImpl = new GameMaster();
        vm.prank(admin);
        master.upgradeToAndCall(address(newImpl), "");
        assertEq(master.owner(), admin);
        assertEq(master.protocolTreasury(), treasury);
    }

    function test_isRoom_falseForUnknown() public {
        assertFalse(master.isRoom(makeAddr("random")));
    }
}
