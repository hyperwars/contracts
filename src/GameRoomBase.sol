// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {IGameRoom} from "./interfaces/IGameRoom.sol";
import {PlayerProxy} from "./PlayerProxy.sol";

abstract contract GameRoomBase is IGameRoom {
    GameConfig internal _config;
    RoundState public state;
    address public proxyImplementation;

    address[] internal _players;
    mapping(address => address) public playerProxy;
    mapping(address => bool) public hasJoined;
    mapping(address => bool) public hasRefunded;
    mapping(address => bool) public isActivated;
    mapping(address => bool) public isProxyDeployed;

    uint256 public activatedCount;
    uint256 public lobbyOpenBlock;
    uint256 public roundStartBlock;
    bool private _initialized;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant AUTHORIZE_AGENT_TYPEHASH =
        keccak256("AuthorizeAgent(address player,address agent,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) public agentNonce;

    mapping(address => uint256) public lastCheckpointBlock;
    mapping(address => mapping(uint32 => uint64)) private _checkpointPx;
    mapping(address => mapping(uint32 => int64)) private _checkpointSzi;
    mapping(address => int256) private _playerScore;

    function initialize(GameConfig calldata config, address proxyImpl) external {
        if (_initialized) revert InvalidConfig();
        _initialized = true;
        if (config.entryBet == 0) revert InvalidConfig();
        if (config.minPlayers < 2) revert InvalidConfig();
        if (config.maxPlayers < config.minPlayers) revert InvalidConfig();
        if (config.joinWindow == 0) revert InvalidConfig();
        if (config.allowedAssets.length == 0) revert EmptyAllowedAssets();
        _config = config;
        proxyImplementation = proxyImpl;
        state = RoundState.LOBBY;
        lobbyOpenBlock = block.number;
    }

    /*//////////////////////////////////////////////////////////////
                                  LOBBY
    //////////////////////////////////////////////////////////////*/

    function register(address player) external {
        if (state != RoundState.LOBBY) revert NotInLobby();
        if (hasJoined[player]) revert AlreadyRegistered();
        if (_players.length >= _config.maxPlayers) revert LobbyFull();

        address proxy = _predictProxy(player);
        uint64 funded = PrecompileLib.spotBalance(proxy, HLConstants.USDC_TOKEN_INDEX).total;
        if (funded < _config.entryBet) revert Underfunded();

        _players.push(player);
        playerProxy[player] = proxy;
        hasJoined[player] = true;
        emit PlayerRegistered(player, proxy, _players.length);

        if (_players.length == _config.maxPlayers) {
            _startRound();
        }
    }

    function cancel() external {
        if (state != RoundState.LOBBY) revert NotInLobby();
        if (block.number < lobbyOpenBlock + _config.joinWindow) {
            revert JoinWindowNotElapsed();
        }
        if (_players.length >= _config.minPlayers) revert MinPlayersReached();
        state = RoundState.CANCELLED;
        emit RoundCancelled(_players.length);
    }

    function refund(address player) external {
        if (state != RoundState.CANCELLED) revert NotCancelled();
        if (!hasJoined[player]) revert NotPlayer();
        if (hasRefunded[player]) revert AlreadyRefunded();
        hasRefunded[player] = true;

        address proxy = _ensureProxy(player);
        uint64 spot = PrecompileLib.spotBalance(proxy, HLConstants.USDC_TOKEN_INDEX).total;
        if (spot > 0) {
            PlayerProxy(payable(proxy)).sendUsdc(player, spot);
        }
        emit Refunded(player, proxy);
    }

    function deployProxy(address player) external returns (address) {
        return _ensureProxy(player);
    }

    /*//////////////////////////////////////////////////////////////
                                  START
    //////////////////////////////////////////////////////////////*/

    function startRound() external {
        if (state != RoundState.LOBBY) revert NotInLobby();
        if (block.number < lobbyOpenBlock + _config.joinWindow) {
            revert JoinWindowNotElapsed();
        }
        if (_players.length < _config.minPlayers) revert BelowMinPlayers();
        _startRound();
    }

    function _startRound() internal {
        roundStartBlock = block.number;
        state = RoundState.STARTING;
        emit RoundStarting(_players.length);
    }

    function activatePlayer(address player) external {
        if (state != RoundState.STARTING) revert NotStarting();
        if (!hasJoined[player]) revert NotPlayer();
        if (isActivated[player]) revert AlreadyActivated();

        address proxy = _ensureProxy(player);
        PlayerProxy(payable(proxy)).activate(uint64(_config.entryBet), _config.builderAddress, _config.builderFeeRate);

        isActivated[player] = true;
        activatedCount++;
        emit PlayerActivated(player, proxy, activatedCount);

        if (activatedCount == _players.length) {
            roundStartBlock = block.number;
            state = RoundState.ACTIVE;
            emit RoundActive(_players.length);
        }
    }

    // Permissionless relay of a player-signed agent-key intent. The signature binds the agent
    // to the player so a front-runner cannot plant their own key on a funded proxy; the nonce
    // makes each intent single-use, so rotation to a new key invalidates every older intent.
    function authorizeAgent(address player, address agent, uint256 deadline, bytes calldata signature) external {
        if (state != RoundState.STARTING && state != RoundState.ACTIVE) revert NotActive();
        if (!isActivated[player]) revert NotActivated();
        if (agent == address(0)) revert InvalidAgent();
        if (block.timestamp > deadline) revert AgentIntentExpired();

        bytes32 structHash =
            keccak256(abi.encode(AUTHORIZE_AGENT_TYPEHASH, player, agent, agentNonce[player], deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        if (ECDSA.recover(digest, signature) != player) revert InvalidAgentSignature();
        agentNonce[player]++;

        address proxy = playerProxy[player];
        PlayerProxy(payable(proxy)).authorizeAgent(agent);
        emit AgentAuthorized(player, proxy, agent);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("HyperwarsGameRoom")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  PLAY
    //////////////////////////////////////////////////////////////*/

    function checkpointPlayer(address player) external {
        if (state != RoundState.ACTIVE) revert NotActive();
        if (!hasJoined[player]) revert NotPlayer();

        address proxy = playerProxy[player];
        uint32[] memory assets = _config.allowedAssets;
        int256 score = _playerScore[player];
        for (uint256 j; j < assets.length; ++j) {
            uint32 asset = assets[j];
            uint64 newPx = PrecompileLib.markPx(asset);
            int256 sziPrev = int256(_checkpointSzi[player][asset]);
            int256 pxDelta = int256(uint256(newPx)) - int256(uint256(_checkpointPx[player][asset]));
            score += sziPrev * pxDelta;
            _checkpointSzi[player][asset] = PrecompileLib.position(proxy, uint16(asset)).szi;
            _checkpointPx[player][asset] = newPx;
        }
        _playerScore[player] = score;
        lastCheckpointBlock[player] = block.number;
        emit Checkpointed(player, score);
    }

    /*//////////////////////////////////////////////////////////////
                                  FINISH
    //////////////////////////////////////////////////////////////*/

    function finish() external {
        if (state != RoundState.ACTIVE) revert NotActive();
        if (block.number < roundStartBlock + _config.maxRoundDuration) {
            revert RoundNotExpired();
        }
        _finish();
    }

    // Hook for derived rooms: the base just releases everyone at FINISHED. A competitive
    // room overrides this to pick a winner and enter settlement instead.
    function _finish() internal virtual {
        state = RoundState.FINISHED;
        emit RoundFinished();
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL / VIEWS
    //////////////////////////////////////////////////////////////*/

    function _salt(address player) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(player));
    }

    function _predictProxy(address player) internal view returns (address) {
        return Clones.predictDeterministicAddress(proxyImplementation, _salt(player), address(this));
    }

    function _ensureProxy(address player) internal returns (address) {
        address proxy = _predictProxy(player);
        if (!isProxyDeployed[player]) {
            isProxyDeployed[player] = true;
            Clones.cloneDeterministic(proxyImplementation, _salt(player));
            PlayerProxy(payable(proxy)).initialize(player, address(this));
            playerProxy[player] = proxy;
        }
        return proxy;
    }

    function canWithdraw(address owner) external view virtual returns (bool) {
        return state == RoundState.CANCELLED || state == RoundState.FINISHED || !hasJoined[owner];
    }

    function validateTrade(address, uint32) external virtual returns (bool) {
        return state == RoundState.ACTIVE;
    }

    function getPlayerScore(address player) public view virtual returns (int256) {
        return _playerScore[player];
    }

    function predictProxy(address player) external view returns (address) {
        return _predictProxy(player);
    }

    function getConfig() external view returns (GameConfig memory) {
        return _config;
    }

    function getPlayers() external view returns (address[] memory) {
        return _players;
    }

    function getPlayerCount() external view returns (uint256) {
        return _players.length;
    }
}
