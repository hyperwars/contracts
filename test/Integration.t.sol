// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GameMaster} from "../src/GameMaster.sol";
import {GameRoomFactory} from "../src/GameRoomFactory.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";

contract IntegrationTest is MockHyperCore {
    GameMaster master;
    GameRoomFactory factory;
    DefaultGameRoom roomImpl;
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
    uint256 constant JOIN_WINDOW = 50;
    uint256 constant MAX_ROUND_DURATION = 1000;

    function setUp() public override {
        super.setUp();

        proxyImpl = new PlayerProxy();
        roomImpl = new DefaultGameRoom();

        GameMaster impl = new GameMaster();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(GameMaster.initialize, (admin, treasury, address(proxyImpl), uint256(0)))
        );
        master = GameMaster(address(proxy));

        factory = new GameRoomFactory(address(roomImpl), address(0), 10, 5, 3600);
        vm.prank(admin);
        master.registerFactory(address(factory));
    }

    function _defaultConfig() internal view returns (IGameRoom.GameConfig memory) {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        return IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            prizePoolShare: 2000,
            sliceCooldown: 100,
            slicerIncentive: 500,
            maxRoundDuration: MAX_ROUND_DURATION,
            joinWindow: JOIN_WINDOW,
            minPlayers: 2,
            maxPlayers: 4,
            allowedAssets: assets,
            builderAddress: address(0),
            builderFeeRate: 0
        });
    }

    function _createRoom() internal returns (DefaultGameRoom) {
        return DefaultGameRoom(master.createRoom(address(factory), _defaultConfig()));
    }

    function _register(DefaultGameRoom room, address player) internal {
        address proxy = room.predictProxy(player);
        hyperCore.forceAccountActivation(proxy);
        hyperCore.forceSpotBalance(proxy, HLConstants.USDC_TOKEN_INDEX, uint64(ENTRY_BET));
        room.register(player);
    }

    function _proxyValue(DefaultGameRoom room, address player) internal returns (uint256) {
        address proxy = room.playerProxy(player);
        uint64 spot = PrecompileLib.spotBalance(proxy, HLConstants.USDC_TOKEN_INDEX).total;
        uint64 perp = PrecompileLib.withdrawable(proxy);
        return uint256(spot) + uint256(perp);
    }

    // Full free-play lifecycle driven by unprivileged keepers: register -> activate -> authorize
    // -> finish. Every player keeps their own capital; the base never moves funds.
    function test_happyPath_freePlay_everyoneKeepsCapital() public {
        DefaultGameRoom room = _createRoom();
        assertTrue(master.isRoom(address(room)));

        _register(room, alice);
        _register(room, bob);
        _register(room, carol);
        _register(room, dave);
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.STARTING));

        address[] memory players = room.getPlayers();

        vm.startPrank(keeper1);
        for (uint256 i; i < players.length; ++i) {
            room.activatePlayer(players[i]);
        }
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.ACTIVE));

        vm.startPrank(keeper2);
        for (uint256 i; i < players.length; ++i) {
            room.authorizeAgent(players[i]);
        }
        vm.stopPrank();
        CoreSimulatorLib.nextBlock();

        // Leaderboard checkpoint while active (no positions -> zero score).
        for (uint256 i; i < players.length; ++i) {
            room.checkpointPlayer(players[i]);
        }

        vm.roll(room.roundStartBlock() + MAX_ROUND_DURATION);
        vm.prank(keeper1);
        room.finish();
        assertEq(uint256(room.state()), uint256(IGameRoom.RoundState.FINISHED));

        // Each player still holds exactly their entry bet; everyone is released.
        for (uint256 i; i < players.length; ++i) {
            assertEq(_proxyValue(room, players[i]), ENTRY_BET);
            assertTrue(room.canWithdraw(players[i]));
        }
    }

    function test_happyPath_winnerlessWithdraw() public {
        DefaultGameRoom room = _createRoom();
        _register(room, alice);
        _register(room, bob);
        _register(room, carol);
        _register(room, dave);

        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            room.activatePlayer(players[i]);
        }
        CoreSimulatorLib.nextBlock();

        vm.roll(room.roundStartBlock() + MAX_ROUND_DURATION);
        room.finish();

        // Alice moves her own margin to spot (as her agent would) then withdraws to her EOA.
        hyperCore.forceAccountActivation(alice);
        address aliceProxy = room.playerProxy(alice);
        vm.prank(address(room));
        PlayerProxy(payable(aliceProxy)).moveMarginToSpot(uint64(ENTRY_BET));
        CoreSimulatorLib.nextBlock();

        vm.prank(alice);
        PlayerProxy(payable(aliceProxy)).withdraw();
        CoreSimulatorLib.nextBlock();

        assertEq(PrecompileLib.spotBalance(alice, HLConstants.USDC_TOKEN_INDEX).total, uint64(ENTRY_BET));
    }
}
