// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {ICoreDepositWallet} from "@hyper-evm-lib/src/interfaces/ICoreDepositWallet.sol";
import {IGameRoom} from "./interfaces/IGameRoom.sol";
import {PlayerProxy} from "./PlayerProxy.sol";

abstract contract GameRoomBase is IGameRoom {
    using SafeERC20 for IERC20;

    uint64 internal constant MIN_BRIDGEABLE_SPOT = 110_000_000; // 1.1 USDC
    uint256 internal constant AGENT_REVOCATION_DELAY = 5; // blocks

    GameConfig internal _config;
    RoundState public state;
    address public proxyImplementation;

    address[] internal _players;
    mapping(address => address) public playerProxy;
    mapping(address => bool) public hasJoined;
    mapping(address => bool) public hasRefunded;
    mapping(address => bool) public isEliminated;

    uint256 public prizePool;
    uint256 public slicerReserve;
    uint256 public activePlayers;
    uint256 public lastSliceBlock;
    uint256 public lastCheckpointBlock;
    uint256 public lobbyOpenBlock;
    bool private _initialized;
    address public winner;
    uint256 public roundStartBlock;
    uint256 public settlementBlock;

    mapping(uint32 => uint64) private _checkpointPx;
    mapping(address => mapping(uint32 => int64)) private _checkpointSzi;
    mapping(address => int256) private _playerScore;

    function initialize(GameConfig calldata config, address proxyImpl) external {
        if (_initialized) revert InvalidConfig();
        _initialized = true;
        if (config.entryBet == 0) revert InvalidConfig();
        if (config.minPlayers < 2) revert InvalidConfig();
        if (config.maxPlayers < config.minPlayers) revert InvalidConfig();
        if (config.joinWindow == 0) revert InvalidConfig();
        if (config.prizePoolShare + config.slicerIncentive >= 10_000) {
            revert InvalidConfig();
        }
        if (config.allowedAssets.length == 0) revert EmptyAllowedAssets();
        _config = config;
        proxyImplementation = proxyImpl;
        state = RoundState.LOBBY;
        lobbyOpenBlock = block.number;
    }

    function join() external {
        if (state != RoundState.LOBBY) revert NotInLobby();
        if (hasJoined[msg.sender]) revert AlreadyJoined();
        if (_players.length >= _config.maxPlayers) revert LobbyFull();
        IERC20(HLConstants.usdc()).safeTransferFrom(msg.sender, address(this), _config.entryBet);
        address proxy = Clones.clone(proxyImplementation);
        PlayerProxy(payable(proxy)).initialize(msg.sender, address(this));
        _players.push(msg.sender);
        playerProxy[msg.sender] = proxy;
        hasJoined[msg.sender] = true;
        emit PlayerJoined(msg.sender, proxy, _players.length);
        if (_players.length == _config.maxPlayers) {
            _startRound();
        }
    }

    function startRound() external {
        if (state != RoundState.LOBBY) revert NotInLobby();
        if (block.number < lobbyOpenBlock + _config.joinWindow) {
            revert JoinWindowNotElapsed();
        }
        if (_players.length < _config.minPlayers) revert BelowMinPlayers();
        _startRound();
    }

    function _startRound() internal {
        uint256 numPlayers = _players.length;
        uint256 prizePoolPerPlayer = (_config.entryBet * _config.prizePoolShare) / 10_000;
        uint256 slicerReservePerPlayer = (_config.entryBet * _config.slicerIncentive) / 10_000;
        uint256 tradingBalance = _config.entryBet - prizePoolPerPlayer - slicerReservePerPlayer;

        prizePool = prizePoolPerPlayer * numPlayers;
        slicerReserve = slicerReservePerPlayer * numPlayers;
        activePlayers = numPlayers;
        lastSliceBlock = block.number;
        roundStartBlock = block.number;
        state = RoundState.ACTIVE;

        uint32[] memory checkpointAssets = _config.allowedAssets;
        for (uint256 i; i < checkpointAssets.length; ++i) {
            _checkpointPx[checkpointAssets[i]] = PrecompileLib.markPx(checkpointAssets[i]);
        }

        address wallet = HLConstants.coreDepositWallet();
        IERC20(HLConstants.usdc()).forceApprove(wallet, tradingBalance * numPlayers);
        for (uint256 i; i < numPlayers; ++i) {
            ICoreDepositWallet(wallet)
                .depositFor(playerProxy[_players[i]], tradingBalance, HLConstants.DEFAULT_PERP_DEX);
        }
        emit RoundStarted(numPlayers, prizePool);
    }

    function activateAgent(address player) external {
        if (state != RoundState.ACTIVE) revert NotActive();
        address proxy = playerProxy[player];
        if (proxy == address(0)) revert NotPlayer();
        PlayerProxy(payable(proxy)).activateAgent(_config.builderAddress, _config.builderFeeRate);
        emit AgentActivated(player, proxy);
    }

    function slice(uint32[] calldata assets) external {
        if (state != RoundState.ACTIVE) revert NotActive();
        if (block.number < lastSliceBlock + _config.sliceCooldown) {
            revert CooldownNotElapsed();
        }

        address target;
        int256 lowestScore = type(int256).max;
        uint256 len = _players.length;
        for (uint256 i; i < len; ++i) {
            address player = _players[i];
            if (isEliminated[player]) continue;
            int256 score = getPlayerScore(player);
            if (score < lowestScore) {
                lowestScore = score;
                target = player;
            }
        }

        if (!canSlice(target)) revert SliceBlocked();
        isEliminated[target] = true;
        activePlayers--;
        lastSliceBlock = block.number;

        uint256 incentive;
        if (activePlayers == 1) {
            incentive = slicerReserve;
        } else {
            incentive = (_config.entryBet * _config.slicerIncentive) / 10_000;
        }
        slicerReserve -= incentive;
        IERC20(HLConstants.usdc()).safeTransfer(msg.sender, incentive);

        PlayerProxy(payable(playerProxy[target])).forceCloseAll(assets);

        if (activePlayers == 1) {
            uint256 pLen = _players.length;
            for (uint256 j; j < pLen; ++j) {
                if (!isEliminated[_players[j]]) {
                    winner = _players[j];
                    break;
                }
            }
            _enterRevoking();
            emit RoundSettled(winner, SettleReason.LastManStanding);
        }

        emit Sliced(target, msg.sender, incentive, activePlayers);
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

    function claimRefund() external {
        if (state != RoundState.CANCELLED) revert NotCancelled();
        if (!hasJoined[msg.sender]) revert NotPlayer();
        if (hasRefunded[msg.sender]) revert AlreadyRefunded();
        hasRefunded[msg.sender] = true;
        IERC20(HLConstants.usdc()).safeTransfer(msg.sender, _config.entryBet);
        emit RefundClaimed(msg.sender, _config.entryBet);
    }

    function settleByTimeLimit() external {
        if (state != RoundState.ACTIVE) revert NotActive();
        if (block.number < roundStartBlock + _config.maxRoundDuration) {
            revert RoundNotExpired();
        }

        address best;
        int256 highestScore = type(int256).min;
        uint256 len = _players.length;
        for (uint256 i; i < len; ++i) {
            address player = _players[i];
            if (isEliminated[player]) continue;
            int256 score = getPlayerScore(player);
            if (score > highestScore) {
                highestScore = score;
                best = player;
            }
        }
        winner = best;
        _enterRevoking();
        emit RoundSettled(winner, SettleReason.TimeLimit);
    }

    function advanceSettlement() external {
        if (state == RoundState.REVOKING_AGENTS) {
            _phaseRevokeAgents();
        } else if (state == RoundState.CLOSING_POSITIONS) {
            _phaseClosePositions();
        } else if (state == RoundState.WITHDRAWING) {
            _phaseWithdraw();
        } else if (state == RoundState.DISTRIBUTING) {
            _phaseDistribute();
        } else {
            revert NotSettling();
        }
    }

    function _enterRevoking() internal {
        uint256 len = _players.length;
        for (uint256 i; i < len; ++i) {
            PlayerProxy(payable(playerProxy[_players[i]])).revokeAgent();
        }
        settlementBlock = block.number;
        state = RoundState.REVOKING_AGENTS;
    }

    function _phaseRevokeAgents() internal {
        if (block.number < settlementBlock + AGENT_REVOCATION_DELAY) return;
        state = RoundState.CLOSING_POSITIONS;
        emit SettlementAdvanced(RoundState.CLOSING_POSITIONS);
    }

    function _phaseClosePositions() internal {
        uint256 len = _players.length;
        uint32[] memory assets = _config.allowedAssets;
        uint256 assetLen = assets.length;

        for (uint256 i; i < len; ++i) {
            PlayerProxy(payable(playerProxy[_players[i]])).forceCloseAll(assets);
        }

        for (uint256 i; i < len; ++i) {
            address proxy = playerProxy[_players[i]];
            for (uint256 j; j < assetLen; ++j) {
                if (PrecompileLib.position(proxy, uint16(assets[j])).szi != 0) {
                    return;
                }
            }
        }

        state = RoundState.WITHDRAWING;
        emit SettlementAdvanced(RoundState.WITHDRAWING);
    }

    function _phaseWithdraw() internal {
        uint256 len = _players.length;

        for (uint256 i; i < len; ++i) {
            PlayerProxy(payable(playerProxy[_players[i]])).withdrawAll();
        }

        for (uint256 i; i < len; ++i) {
            address proxy = playerProxy[_players[i]];
            if (PrecompileLib.withdrawable(proxy) != 0) return;
            if (PrecompileLib.spotBalance(proxy, HLConstants.USDC_TOKEN_INDEX).total >= MIN_BRIDGEABLE_SPOT) return;
        }

        state = RoundState.DISTRIBUTING;
        emit SettlementAdvanced(RoundState.DISTRIBUTING);
    }

    function _phaseDistribute() internal {
        uint256 len = _players.length;
        address usdc = HLConstants.usdc();

        for (uint256 i; i < len; ++i) {
            address proxy = playerProxy[_players[i]];
            PlayerProxy(payable(proxy)).sweepFunds(_sweepRecipient(proxy));
        }

        uint256 totalPayout = IERC20(usdc).balanceOf(address(this));
        address winnerProxy = playerProxy[winner];
        address payoutAddress = _winnerPayoutAddress(winnerProxy);
        state = RoundState.FINISHED;
        IERC20(usdc).safeTransfer(payoutAddress, totalPayout);
        emit PrizeDistributed(winner, totalPayout);
        emit RoundFinished(winner, totalPayout);
    }

    function checkpoint() external {
        if (state != RoundState.ACTIVE) revert NotActive();

        uint32[] memory assets = _config.allowedAssets;
        uint256 assetLen = assets.length;
        uint256 playerLen = _players.length;

        uint64[] memory newPx = new uint64[](assetLen);
        for (uint256 j; j < assetLen; ++j) {
            newPx[j] = PrecompileLib.markPx(assets[j]);
        }

        for (uint256 i; i < playerLen; ++i) {
            address player = _players[i];
            if (isEliminated[player]) continue;
            address proxy = playerProxy[player];
            for (uint256 j; j < assetLen; ++j) {
                uint32 asset = assets[j];
                int256 sziPrev = int256(_checkpointSzi[player][asset]);
                int256 pxDelta = int256(uint256(newPx[j])) - int256(uint256(_checkpointPx[asset]));
                _playerScore[player] += sziPrev * pxDelta;
                _checkpointSzi[player][asset] = PrecompileLib.position(proxy, uint16(asset)).szi;
            }
        }

        for (uint256 j; j < assetLen; ++j) {
            _checkpointPx[assets[j]] = newPx[j];
        }

        lastCheckpointBlock = block.number;
        emit Checkpointed(block.number);
    }

    function _sweepRecipient(
        address /*proxy*/
    )
        internal
        view
        virtual
        returns (address)
    {
        return address(this);
    }

    function _winnerPayoutAddress(address proxy) internal view virtual returns (address) {
        return PlayerProxy(payable(proxy)).owner();
    }

    function validateTrade(address player, uint32) external virtual returns (bool) {
        return state == RoundState.ACTIVE && !isEliminated[player];
    }

    function getPlayerScore(address player) public view virtual returns (int256) {
        if (isEliminated[player]) return _playerScore[player];
        uint32[] memory assets = _config.allowedAssets;
        uint256 len = assets.length;
        int256 live;
        for (uint256 i; i < len; ++i) {
            uint32 asset = assets[i];
            int64 szi = _checkpointSzi[player][asset];
            if (szi == 0) continue;
            int256 pxDelta = int256(uint256(PrecompileLib.markPx(asset))) - int256(uint256(_checkpointPx[asset]));
            live += int256(szi) * pxDelta;
        }
        return _playerScore[player] + live;
    }

    function canSlice(address) internal virtual returns (bool) {
        return true;
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
