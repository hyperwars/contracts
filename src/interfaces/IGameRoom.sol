// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGameRoom {
    enum RoundState {
        LOBBY,
        ACTIVE,
        REVOKING_AGENTS,
        CLOSING_POSITIONS,
        WITHDRAWING,
        DISTRIBUTING,
        FINISHED,
        CANCELLED
    }

    enum SettleReason {
        LastManStanding,
        TimeLimit
    }

    struct GameConfig {
        uint256 entryBet;
        uint256 sliceCooldown;
        uint256 slicerIncentive; // bps (500 = 5%)
        uint256 maxRoundDuration;
        uint256 joinWindow; // blocks
        uint8 minPlayers;
        uint8 maxPlayers;
        uint64 builderFeeRate;
        uint256 prizePoolShare; // bps (2000 = 20%)
        uint32[] allowedAssets;
        address builderAddress;
    }

    event Checkpointed(uint256 blockNumber);
    event PlayerJoined(address indexed player, address indexed proxy, uint256 playerCount);
    event RoundStarted(uint256 playerCount, uint256 prizePool);
    event AgentActivated(address indexed player, address indexed proxy);
    event RoundCancelled(uint256 playerCount);
    event RefundClaimed(address indexed player, uint256 amount);
    event Sliced(address indexed target, address indexed slicer, uint256 incentive, uint256 activePlayers);
    event RoundSettled(address indexed winner, SettleReason reason);
    event SettlementAdvanced(RoundState newPhase);
    event PrizeDistributed(address indexed winner, uint256 amount);
    event RoundFinished(address indexed winner, uint256 totalPayout);

    error NotInLobby();
    error AlreadyJoined();
    error LobbyFull();
    error JoinWindowNotElapsed();
    error BelowMinPlayers();
    error MinPlayersReached();
    error NotCancelled();
    error NotPlayer();
    error AlreadyRefunded();
    error InvalidConfig();
    error NotActive();
    error CooldownNotElapsed();
    error SliceBlocked();
    error NotSettling();
    error RoundNotExpired();
    error EmptyAllowedAssets();

    function validateTrade(address player, uint32 asset) external returns (bool);

    function join() external;
    function checkpoint() external;
    function claimRefund() external;

    function startRound() external;
    function activateAgent(address player) external;
    function cancel() external;
    function slice(uint32[] calldata assets) external;
    function settleByTimeLimit() external;
    function advanceSettlement() external;

    function getPlayerScore(address player) external view returns (int256);

    function getConfig() external view returns (GameConfig memory);
    function getPlayers() external view returns (address[] memory);
    function getPlayerCount() external view returns (uint256);
}
