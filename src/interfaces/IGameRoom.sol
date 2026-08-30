// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGameRoom {
    enum RoundState {
        LOBBY,
        STARTING,
        ACTIVE,
        // Reserved for a future settlement window; no contract transitions to this state yet.
        SETTLING,
        FINISHED,
        CANCELLED
    }

    struct GameConfig {
        uint256 entryBet;
        uint256 maxRoundDuration;
        uint256 joinWindow; // blocks
        uint8 minPlayers;
        uint8 maxPlayers;
        uint64 builderFeeRate;
        uint32[] allowedAssets;
        address builderAddress;
    }

    event Checkpointed(address indexed player, int256 score);
    event PlayerRegistered(address indexed player, address indexed proxy, uint256 playerCount);
    event RoundStarting(uint256 playerCount);
    event PlayerActivated(address indexed player, address indexed proxy, uint256 activatedCount);
    event RoundActive(uint256 playerCount);
    event AgentAuthorized(address indexed player, address indexed proxy, address agent);
    event RoundCancelled(uint256 playerCount);
    event Refunded(address indexed player, address indexed proxy);
    event RoundFinished();

    error NotInLobby();
    error AlreadyRegistered();
    error LobbyFull();
    error JoinWindowNotElapsed();
    error BelowMinPlayers();
    error MinPlayersReached();
    error NotCancelled();
    error NotPlayer();
    error AlreadyRefunded();
    error InvalidConfig();
    error NotStarting();
    error NotActive();
    error AlreadyActivated();
    error NotActivated();
    error EmptyAllowedAssets();
    error Underfunded();
    error RoundNotExpired();
    error AgentIntentExpired();
    error InvalidAgent();
    error InvalidAgentSignature();

    function validateTrade(address player, uint32 asset) external returns (bool);
    function canWithdraw(address owner) external view returns (bool);

    function register(address player) external;
    function checkpointPlayer(address player) external;
    function refund(address player) external;
    function deployProxy(address player) external returns (address);

    function startRound() external;
    function activatePlayer(address player) external;
    function authorizeAgent(address player, address agent, uint256 deadline, bytes calldata signature) external;
    function cancel() external;
    function finish() external;

    function getPlayerScore(address player) external view returns (int256);

    function predictProxy(address player) external view returns (address);
    function getConfig() external view returns (GameConfig memory);
    function getPlayers() external view returns (address[] memory);
    function getPlayerCount() external view returns (uint256);
}
