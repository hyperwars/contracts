// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IGameRoom} from "./interfaces/IGameRoom.sol";
import {IGameRoomFactory} from "./interfaces/IGameRoomFactory.sol";

contract GameMaster is OwnableUpgradeable, UUPSUpgradeable {
    address public protocolTreasury;
    address public userProxyImplementation;

    mapping(address => bool) public isFactory;
    mapping(address => address) public roomFactory;

    uint256 public minTradingBalance;

    event FactoryRegistered(address indexed factory);
    event FactoryDeregistered(address indexed factory);
    event RoomCreated(address indexed room, address indexed factory, address indexed creator);

    error ZeroAddress();
    error FactoryNotActive();
    error EntryBetTooSmall();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address protocolTreasury_,
        address userProxyImplementation_,
        uint256 minTradingBalance_
    ) external initializer {
        if (protocolTreasury_ == address(0)) revert ZeroAddress();
        if (userProxyImplementation_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);

        protocolTreasury = protocolTreasury_;
        userProxyImplementation = userProxyImplementation_;
        minTradingBalance = minTradingBalance_;
    }

    function registerFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        isFactory[factory] = true;
        emit FactoryRegistered(factory);
    }

    function deregisterFactory(address factory) external onlyOwner {
        isFactory[factory] = false;
        emit FactoryDeregistered(factory);
    }

    function createRoom(address factory, IGameRoom.GameConfig calldata config) external returns (address room) {
        if (!isFactory[factory]) revert FactoryNotActive();

        if (IGameRoomFactory(factory).tradingBalancePerPlayer(config) < minTradingBalance) {
            revert EntryBetTooSmall();
        }

        address factoryBuilder = IGameRoomFactory(factory).builderFeeRecipient();
        IGameRoom.GameConfig memory cfg = config;
        cfg.builderAddress = factoryBuilder != address(0) ? factoryBuilder : protocolTreasury;

        room = IGameRoomFactory(factory).createRoom(cfg, userProxyImplementation);
        roomFactory[room] = factory;

        emit RoomCreated(room, factory, msg.sender);
    }

    function setProtocolTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();
        protocolTreasury = treasury;
    }

    function setMinTradingBalance(uint256 minTradingBalance_) external onlyOwner {
        minTradingBalance = minTradingBalance_;
    }

    function setProxyImplementation(address impl) external onlyOwner {
        if (impl == address(0)) revert ZeroAddress();
        userProxyImplementation = impl;
    }

    function isRoom(address room) external view returns (bool) {
        return roomFactory[room] != address(0);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
