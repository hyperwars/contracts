// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlayerProxy} from "../src/PlayerProxy.sol";
import {IGameRoom} from "../src/interfaces/IGameRoom.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";
import {HarnessGameRoom} from "./mocks/HarnessGameRoom.sol";

abstract contract GameRoomBaseTestBase is MockHyperCore {
    HarnessGameRoom room;
    PlayerProxy proxyImpl;

    uint256 constant ENTRY_BET = 100e6; // 100 USDC
    uint8 constant MIN_PLAYERS = 2;
    uint8 constant MAX_PLAYERS = 4;
    uint256 constant JOIN_WINDOW = 50; // blocks
    uint256 constant MAX_ROUND_DURATION = 1000; // blocks

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address keeper = makeAddr("keeper");

    mapping(address => uint256) internal playerPk;

    function setUp() public virtual override {
        super.setUp();

        proxyImpl = new PlayerProxy();
        room = new HarnessGameRoom();

        room.initialize(_defaultConfig(), address(proxyImpl));

        // makeAddrAndKey derives the same address as makeAddr for the same label.
        string[4] memory labels = ["alice", "bob", "carol", "dave"];
        for (uint256 i; i < labels.length; ++i) {
            (address addr, uint256 pk) = makeAddrAndKey(labels[i]);
            playerPk[addr] = pk;
        }
    }

    function _defaultConfig() internal view returns (IGameRoom.GameConfig memory) {
        uint32[] memory allowedAssets = new uint32[](1);
        allowedAssets[0] = BTC_PERP;
        return IGameRoom.GameConfig({
            entryBet: ENTRY_BET,
            maxRoundDuration: MAX_ROUND_DURATION,
            joinWindow: JOIN_WINDOW,
            minPlayers: MIN_PLAYERS,
            maxPlayers: MAX_PLAYERS,
            allowedAssets: allowedAssets,
            builderAddress: address(0),
            builderFeeRate: 0
        });
    }

    function _fundProxy(address player, uint64 amount) internal returns (address proxy) {
        proxy = room.predictProxy(player);
        hyperCore.forceAccountActivation(proxy);
        hyperCore.forceSpotBalance(proxy, HLConstants.USDC_TOKEN_INDEX, amount);
    }

    function _register(address player) internal {
        _fundProxy(player, uint64(ENTRY_BET));
        room.register(player);
    }

    function _registerMin() internal {
        _register(alice);
        _register(bob);
    }

    function _activateAll() internal {
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            room.activatePlayer(players[i]);
        }
        CoreSimulatorLib.nextBlock();
    }

    function _agentOf(address player) internal returns (address) {
        return makeAddr(string.concat("agent:", vm.toString(player)));
    }

    function _signAuthorizeAgent(address player, address agent, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signAuthorizeAgentAs(player, player, agent, nonce, deadline);
    }

    function _signAuthorizeAgentAs(address signer, address player, address agent, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("HyperwarsGameRoom")),
                keccak256(bytes("1")),
                block.chainid,
                address(room)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AuthorizeAgent(address player,address agent,uint256 nonce,uint256 deadline)"),
                player,
                agent,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(playerPk[signer], digest);
        return abi.encodePacked(r, s, v);
    }

    function _authorize(address player) internal {
        address agent = _agentOf(player);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signAuthorizeAgent(player, agent, room.agentNonce(player), deadline);
        room.authorizeAgent(player, agent, deadline, sig);
    }

    function _authorizeAll() internal {
        address[] memory players = room.getPlayers();
        for (uint256 i; i < players.length; ++i) {
            _authorize(players[i]);
        }
        CoreSimulatorLib.nextBlock();
    }

    // Registers four players (auto-starts at maxPlayers) and activates everyone to ACTIVE.
    function _fillAndStart() internal {
        _register(alice);
        _register(bob);
        _register(carol);
        _register(dave);
        _activateAll();
    }

    function _mockPositionOpen(address proxy, uint32 asset, int64 szi) internal {
        PrecompileLib.Position memory pos =
            PrecompileLib.Position({szi: szi, entryNtl: 0, isolatedRawUsd: 0, leverage: 1, isIsolated: false});
        vm.mockCall(HLConstants.POSITION_PRECOMPILE_ADDRESS, abi.encode(proxy, uint16(asset)), abi.encode(pos));
    }

    function _mockPositionClosed(address proxy, uint32 asset) internal {
        _mockPositionOpen(proxy, asset, 0);
    }

    // Rolls past the round duration and finishes the round.
    function _finishRound() internal {
        vm.roll(room.roundStartBlock() + MAX_ROUND_DURATION);
        room.finish();
    }

    function _spotOf(address player) internal view returns (uint64) {
        return PrecompileLib.spotBalance(room.playerProxy(player), HLConstants.USDC_TOKEN_INDEX).total;
    }

    function _perpOf(address player) internal returns (uint64) {
        return PrecompileLib.withdrawable(room.playerProxy(player));
    }
}
