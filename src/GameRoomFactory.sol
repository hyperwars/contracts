// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {IGameRoom} from "./interfaces/IGameRoom.sol";
import {IGameRoomFactory} from "./interfaces/IGameRoomFactory.sol";
import {GameRoomBase} from "./GameRoomBase.sol";

contract GameRoomFactory is IGameRoomFactory {
    address public immutable roomImplementation;
    address public immutable builderFeeRecipient;
    uint256 public immutable maxPlayers;
    uint256 public immutable maxAssets;
    uint256 public immutable maxRoundDuration;

    // HL requires this perp account value for a builder to be approvable;
    // approveBuilderFee for a poorer builder is silently dropped by HyperCore.
    int64 private constant MIN_BUILDER_PERP_VALUE = 100e6;

    error MaxPlayersExceeded();
    error MaxAssetsExceeded();
    error MaxRoundDurationExceeded();
    error BuilderNotEligible();

    constructor(
        address roomImpl,
        address builderFeeRecipient_,
        uint256 maxPlayers_,
        uint256 maxAssets_,
        uint256 maxRoundDuration_
    ) {
        roomImplementation = roomImpl;
        builderFeeRecipient = builderFeeRecipient_;
        maxPlayers = maxPlayers_;
        maxAssets = maxAssets_;
        maxRoundDuration = maxRoundDuration_;
    }

    function createRoom(IGameRoom.GameConfig calldata config, address proxyImpl) external returns (address room) {
        if (config.maxPlayers > maxPlayers) revert MaxPlayersExceeded();
        if (config.allowedAssets.length > maxAssets) revert MaxAssetsExceeded();
        if (config.maxRoundDuration > maxRoundDuration) revert MaxRoundDurationExceeded();
        if (config.builderFeeRate > 0) {
            PrecompileLib.AccountMarginSummary memory summary =
                PrecompileLib.accountMarginSummary(HLConstants.DEFAULT_PERP_DEX, config.builderAddress);
            if (summary.accountValue < MIN_BUILDER_PERP_VALUE) revert BuilderNotEligible();
        }
        room = Clones.clone(roomImplementation);
        GameRoomBase(room).initialize(config, proxyImpl);
    }
}
