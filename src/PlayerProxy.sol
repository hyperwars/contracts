// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CoreWriterLib} from "@hyper-evm-lib/src/CoreWriterLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {HLConversions} from "@hyper-evm-lib/src/common/HLConversions.sol";
import {IGameRoom} from "./interfaces/IGameRoom.sol";

contract PlayerProxy {
    using SafeERC20 for IERC20;

    address public owner;
    address public gameRoom;
    bool private _initialized;

    uint256 private constant FORCE_CLOSE_SLIPPAGE_BPS = 1_000; // 10%

    uint64 internal constant ACTIVATION_FEE_BUFFER = 110_000_000; // 1.1 core USDC
    address internal constant BURN_AGENT = 0x000000000000000000000000000000000000dEaD;

    error AlreadyInitialized();
    error Unauthorized();

    event Initialized(address indexed owner, address indexed gameRoom);
    event AgentActivated(address indexed owner);
    event AgentRevoked(address indexed owner);
    event UsdcMoved(uint64 amount, bool toPerp);
    event FundsSwept(address indexed recipient, uint256 amount);
    event OwnerChanged(address indexed newOwner);

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

    function activateAgent(address builder, uint64 rate) external onlyGameRoom {
        if (builder != address(0) && rate > 0) {
            CoreWriterLib.approveBuilderFee(rate, builder);
        }
        CoreWriterLib.addApiWallet(owner, "");
        emit AgentActivated(owner);
    }

    function revokeAgent() external onlyGameRoom {
        CoreWriterLib.addApiWallet(BURN_AGENT, "");
        emit AgentRevoked(owner);
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

    function moveUsdc(uint64 amount, bool toPerp) external onlyOwner {
        CoreWriterLib.transferUsdClass(amount, toPerp);
        emit UsdcMoved(amount, toPerp);
    }

    function changeOwner(address newOwner) external onlyOwner {
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    function forceCloseAll(uint32[] calldata assets) external onlyGameRoom {
        for (uint256 i; i < assets.length; ++i) {
            _closePosition(assets[i]);
        }
    }

    function withdrawAll() external onlyGameRoom {
        uint64 withdrawable = PrecompileLib.withdrawable(address(this));
        if (withdrawable > 0) {
            CoreWriterLib.transferUsdClass(withdrawable, false);
        }

        PrecompileLib.SpotBalance memory bal = PrecompileLib.spotBalance(address(this), HLConstants.USDC_TOKEN_INDEX);
        if (bal.total > ACTIVATION_FEE_BUFFER) {
            uint64 sendAmount = bal.total - ACTIVATION_FEE_BUFFER;
            uint256 evmAmount = HLConversions.weiToEvm(HLConstants.USDC_TOKEN_INDEX, sendAmount);
            if (evmAmount > 0) {
                CoreWriterLib.bridgeToEvm(HLConstants.usdc(), evmAmount);
            }
        }
    }

    function sweepFunds(address recipient) external onlyGameRoom {
        address usdc = HLConstants.usdc();
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        if (balance > 0) {
            IERC20(usdc).safeTransfer(recipient, balance);
        }
        emit FundsSwept(recipient, balance);
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
