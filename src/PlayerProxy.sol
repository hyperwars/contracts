// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IGameRoom} from "./interfaces/IGameRoom.sol";

contract PlayerProxy {
    address public owner;
    address public gameRoom;
    bool private _initialized;

    uint256 private constant FORCE_CLOSE_SLIPPAGE_BPS = 1_000; // 10%
    address internal constant BURN_AGENT = 0x000000000000000000000000000000000000dEaD;
    uint64 private constant EXIT_BUFFER = 1e6;

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant EXIT_TYPEHASH = keccak256("Exit(address owner,uint256 deadline)");

    error AlreadyInitialized();
    error Unauthorized();
    error WithdrawLocked();
    error ExitExpired();

    event Initialized(address indexed owner, address indexed gameRoom);
    event Activated(address indexed owner, uint64 tradingBalance);
    event AgentAuthorized(address indexed owner);
    event AgentRevoked(address indexed owner);
    event MarginMovedToSpot(uint64 amount);
    event UsdcSent(address indexed to, uint64 amount);
    event Withdrawn(address indexed owner, uint64 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyGameRoom() {
        if (msg.sender != gameRoom) revert Unauthorized();
        _;
    }

    function initialize(address _owner, address _gameRoom) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        owner = _owner;
        gameRoom = _gameRoom;
        emit Initialized(_owner, _gameRoom);
    }

    function activate(uint64 tradingBalance, address builder, uint64 rate) external onlyGameRoom {
        if (builder != address(0) && rate > 0) {
            CoreWriterLib.approveBuilderFee(rate, builder);
        }
        if (tradingBalance > 0) {
            CoreWriterLib.transferUsdClass(tradingBalance, true);
        }
        emit Activated(owner, tradingBalance);
    }

    function authorizeAgent() external onlyGameRoom {
        CoreWriterLib.addApiWallet(owner, "");
        emit AgentAuthorized(owner);
    }

    function revokeAgent() external onlyGameRoom {
        CoreWriterLib.addApiWallet(BURN_AGENT, "");
        emit AgentRevoked(owner);
    }

    function forceCloseAll(uint32[] calldata assets) external onlyGameRoom {
        for (uint256 i; i < assets.length; ++i) {
            _closePosition(assets[i]);
        }
    }

    function moveMarginToSpot(uint64 amount) external onlyGameRoom {
        CoreWriterLib.transferUsdClass(amount, false);
        emit MarginMovedToSpot(amount);
    }

    function sendUsdc(address to, uint64 amount) external onlyGameRoom {
        CoreWriterLib.spotSend(to, HLConstants.USDC_TOKEN_INDEX, amount);
        emit UsdcSent(to, amount);
    }

    // Owner self-recovery: only when the room permits it (cancelled round, or the owner was
    // never a committed player of a started round). Sends the proxy's spot USDC to the owner.
    function withdraw() external onlyOwner {
        if (!IGameRoom(gameRoom).canWithdraw(owner)) revert WithdrawLocked();
        uint64 spot = PrecompileLib.spotBalance(address(this), HLConstants.USDC_TOKEN_INDEX).total;
        if (spot > 0) {
            CoreWriterLib.spotSend(owner, HLConstants.USDC_TOKEN_INDEX, spot);
        }
        emit Withdrawn(owner, spot);
    }

    function exit(uint256 deadline, bytes calldata signature) external {
        if (block.timestamp > deadline) revert ExitExpired();
        bytes32 structHash = keccak256(abi.encode(EXIT_TYPEHASH, owner, deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
        if (ECDSA.recover(digest, signature) != owner) revert Unauthorized();
        if (!IGameRoom(gameRoom).canWithdraw(owner)) revert WithdrawLocked();

        uint64 wd = PrecompileLib.withdrawable(address(this));
        if (wd > EXIT_BUFFER) {
            CoreWriterLib.transferUsdClass(wd, false);
            emit MarginMovedToSpot(wd);
            return;
        }
        uint64 spot = PrecompileLib.spotBalance(address(this), HLConstants.USDC_TOKEN_INDEX).total;
        if (spot > EXIT_BUFFER) {
            CoreWriterLib.spotSend(owner, HLConstants.USDC_TOKEN_INDEX, spot);
        }
        emit Withdrawn(owner, spot);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("HyperwarsPlayerProxy")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function _closePosition(uint32 asset) internal {
        PrecompileLib.Position memory pos = PrecompileLib.position(address(this), uint16(asset));
        if (pos.szi == 0) return;

        uint64 oracle = PrecompileLib.oraclePx(asset);
        uint64 absSz = pos.szi > 0 ? uint64(pos.szi) : uint64(-pos.szi);
        bool isBuy = pos.szi < 0;

        uint64 limitPx;
        if (isBuy) {
            limitPx = uint64((uint256(oracle) * (10_000 + FORCE_CLOSE_SLIPPAGE_BPS)) / 10_000);
        } else {
            limitPx = uint64((uint256(oracle) * (10_000 - FORCE_CLOSE_SLIPPAGE_BPS)) / 10_000);
        }

        CoreWriterLib.placeLimitOrder(asset, isBuy, limitPx, absSz, true, HLConstants.LIMIT_ORDER_TIF_IOC, 0);
    }

    function getPosition(uint16 asset) external view returns (PrecompileLib.Position memory) {
        return PrecompileLib.position(address(this), asset);
    }

    function getMarginSummary() external view returns (PrecompileLib.AccountMarginSummary memory) {
        return PrecompileLib.accountMarginSummary(HLConstants.DEFAULT_PERP_DEX, address(this));
    }

    function getOraclePrice(uint32 asset) external view returns (uint64) {
        return PrecompileLib.oraclePx(asset);
    }

    function getMarkPrice(uint32 asset) external view returns (uint64) {
        return PrecompileLib.markPx(asset);
    }

    function getBbo(uint32 asset) external view returns (uint64 bid, uint64 ask) {
        PrecompileLib.Bbo memory bbo = PrecompileLib.bbo(uint64(asset));
        return (bbo.bid, bbo.ask);
    }

    receive() external payable {}
}
