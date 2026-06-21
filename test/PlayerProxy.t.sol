// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";
import {MockGameRoom} from "./mocks/MockGameRoom.sol";
import {MockHyperCore} from "./mocks/MockHyperCore.sol";

contract PlayerProxyTest is MockHyperCore {
    PlayerProxy implementation;
    PlayerProxy proxy;
    MockGameRoom mockGameRoom;

    address playerOwner = makeAddr("playerOwner");
    address builderAddr = makeAddr("builder");
    address stranger = makeAddr("stranger");
    uint64 builderFeeRate = 100; // 1%

    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    uint64 constant SEED_PERP_USD = 200e6;

    function setUp() public override {
        super.setUp();

        _mockTokenInfoForUsdc();

        mockGameRoom = new MockGameRoom();
        implementation = new PlayerProxy();

        address clone = Clones.clone(address(implementation));
        proxy = PlayerProxy(payable(clone));

        hyperCore.forceAccountActivation(address(proxy));
        hyperCore.forcePerpBalance(address(proxy), SEED_PERP_USD);

        proxy.initialize(playerOwner, address(mockGameRoom));
    }

    function _mockTokenInfoForUsdc() internal {
        uint64[] memory spots = new uint64[](0);
        PrecompileLib.TokenInfo memory info = PrecompileLib.TokenInfo({
            name: "USDC",
            spots: spots,
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: HLConstants.usdc(),
            szDecimals: 6,
            weiDecimals: 6,
            evmExtraWeiDecimals: 0
        });
        vm.mockCall(
            HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS,
            abi.encode(uint64(HLConstants.USDC_TOKEN_INDEX)),
            abi.encode(info)
        );
        vm.mockCall(
            HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS,
            abi.encode(uint32(HLConstants.USDC_TOKEN_INDEX)),
            abi.encode(info)
        );
    }

    function _bindUsdcEvmContract() internal {
        uint64[] memory spots = new uint64[](0);
        hyperCore.registerTokenInfo(
            HLConstants.USDC_TOKEN_INDEX,
            PrecompileLib.TokenInfo({
                name: "USDC",
                spots: spots,
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: HLConstants.usdc(),
                szDecimals: 6,
                weiDecimals: 6,
                evmExtraWeiDecimals: 0
            })
        );
    }

    function _freshProxy(string memory label) internal returns (PlayerProxy) {
        address clone = Clones.clone(address(implementation));
        PlayerProxy freshProxy = PlayerProxy(payable(clone));
        hyperCore.forceAccountActivation(address(freshProxy));
        hyperCore.forcePerpBalance(address(freshProxy), SEED_PERP_USD);
        freshProxy.initialize(makeAddr(label), address(mockGameRoom));
        return freshProxy;
    }

    function _coreWriterLogCount(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == CORE_WRITER) ++count;
        }
    }

    function test_initialize_setsOwnerAndGameRoom() public view {
        assertEq(proxy.owner(), playerOwner);
        assertEq(proxy.gameRoom(), address(mockGameRoom));
    }

    function test_initialize_revertsOnReInit() public {
        vm.expectRevert(PlayerProxy.AlreadyInitialized.selector);
        proxy.initialize(playerOwner, address(mockGameRoom));
    }

    // initialize() must not touch CoreWriter: Core silently drops addApiWallet for an
    // account it does not yet know (issue #52). Registration is deferred to activateAgent().
    function test_initialize_emitsNoCoreWriterActions() public {
        vm.recordLogs();
        _freshProxy("freshInit");
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 0);
    }

    // activateAgent enqueues an addApiWallet action for the player EOA; nextBlock() dispatches
    // it. In production this authorizes the EOA to sign orders for the proxy's sub-account.
    function test_activateAgent_registersApiWallet() public {
        PlayerProxy freshProxy = _freshProxy("freshActivate");

        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        freshProxy.activateAgent(address(0), 0);
        assertGt(_coreWriterLogCount(vm.getRecordedLogs()), 0);

        CoreSimulatorLib.nextBlock();
    }

    function test_activateAgent_emitsAgentActivated() public {
        PlayerProxy freshProxy = _freshProxy("freshEvent");

        vm.expectEmit(true, false, false, false);
        emit PlayerProxy.AgentActivated(makeAddr("freshEvent"));
        vm.prank(address(mockGameRoom));
        freshProxy.activateAgent(address(0), 0);
    }

    function test_activateAgent_approvesBuilderFee() public {
        PlayerProxy freshProxy = _freshProxy("freshBuilderFee");

        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        freshProxy.activateAgent(makeAddr("freshBuilder"), 5);
        // Two CoreWriter actions: approveBuilderFee + addApiWallet.
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 2);

        CoreSimulatorLib.nextBlock();
    }

    function test_activateAgent_skipsBuilderFeeWhenZeroAddress() public {
        PlayerProxy freshProxy = _freshProxy("freshNoBuilder");

        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        freshProxy.activateAgent(address(0), 5);
        // Only addApiWallet; builder fee skipped when builder is the zero address.
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 1);

        CoreSimulatorLib.nextBlock();
    }

    function test_activateAgent_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.activateAgent(builderAddr, builderFeeRate);
    }

    function test_activateAgent_revertsForOwner() public {
        vm.prank(playerOwner);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.activateAgent(builderAddr, builderFeeRate);
    }

    function test_revokeAgent_enqueuesApiWallet() public {
        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        proxy.revokeAgent();
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 1);

        CoreSimulatorLib.nextBlock();
    }

    function test_revokeAgent_emitsAgentRevoked() public {
        vm.expectEmit(true, false, false, false);
        emit PlayerProxy.AgentRevoked(playerOwner);
        vm.prank(address(mockGameRoom));
        proxy.revokeAgent();
    }

    function test_revokeAgent_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.revokeAgent();
    }

    function test_revokeAgent_revertsForOwner() public {
        vm.prank(playerOwner);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.revokeAgent();
    }

    function test_moveUsdc_emitsEvent() public {
        vm.prank(playerOwner);
        vm.expectEmit(false, false, false, true);
        emit PlayerProxy.UsdcMoved(50e6, false);
        proxy.moveUsdc(50e6, false);
    }

    function test_moveUsdc_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.moveUsdc(50e6, false);
    }

    function test_forceCloseAll_fromGameRoom_noRevert() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        vm.prank(address(mockGameRoom));
        proxy.forceCloseAll(assets); // No revert = success
    }

    function test_forceCloseAll_multipleAssets() public {
        address clone2 = Clones.clone(address(implementation));
        PlayerProxy proxy2 = PlayerProxy(payable(clone2));
        hyperCore.forceAccountActivation(address(proxy2));
        hyperCore.forcePerpBalance(address(proxy2), SEED_PERP_USD);
        proxy2.initialize(playerOwner, address(mockGameRoom));

        uint32[] memory assets = new uint32[](2);
        assets[0] = 0; // BTC
        assets[1] = 1; // ETH

        vm.prank(address(mockGameRoom));
        proxy2.forceCloseAll(assets); // No revert
    }

    function test_sweepFunds_fromGameRoom() public {
        address recipient = makeAddr("recipient");

        vm.prank(address(mockGameRoom));
        vm.expectEmit(true, false, false, false);
        emit PlayerProxy.FundsSwept(recipient, 0);
        proxy.sweepFunds(recipient);
    }

    function test_withdrawAll_fromGameRoom() public {
        vm.prank(address(mockGameRoom));
        proxy.withdrawAll();
    }

    function test_withdrawAll_leavesActivationFeeBuffer() public {
        _bindUsdcEvmContract();
        PlayerProxy p = _freshProxy("bufferProxy");
        hyperCore.forcePerpBalance(address(p), 0);
        uint64 spot = 200_000_000;
        hyperCore.forceSpotBalance(address(p), HLConstants.USDC_TOKEN_INDEX, spot);

        vm.prank(address(mockGameRoom));
        p.withdrawAll();
        CoreSimulatorLib.nextBlock();

        assertEq(PrecompileLib.spotBalance(address(p), HLConstants.USDC_TOKEN_INDEX).total, 110_000_000);
        assertEq(IERC20(HLConstants.usdc()).balanceOf(address(p)), spot - 110_000_000);
    }

    function test_withdrawAll_skipsBridgeWhenAtOrBelowBuffer() public {
        PlayerProxy p = _freshProxy("dustProxy");
        hyperCore.forcePerpBalance(address(p), 0);
        uint64 spot = 110_000_000;
        hyperCore.forceSpotBalance(address(p), HLConstants.USDC_TOKEN_INDEX, spot);

        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        p.withdrawAll();
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 0);

        CoreSimulatorLib.nextBlock();
        assertEq(PrecompileLib.spotBalance(address(p), HLConstants.USDC_TOKEN_INDEX).total, spot);
    }

    function test_forceCloseAll_revertsForOwner() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        vm.prank(playerOwner);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.forceCloseAll(assets);
    }

    function test_forceCloseAll_revertsForStranger() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;

        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.forceCloseAll(assets);
    }

    function test_sweepFunds_revertsForOwner() public {
        vm.prank(playerOwner);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.sweepFunds(playerOwner);
    }

    function test_withdrawAll_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.withdrawAll();
    }

    function test_getOraclePrice_nonZero() public view {
        assertGt(proxy.getOraclePrice(BTC_PERP), 0);
    }

    function test_getMarkPrice_nonZero() public view {
        assertGt(proxy.getMarkPrice(BTC_PERP), 0);
    }

    function test_getBbo_bidLteAsk() public view {
        (uint64 bid, uint64 ask) = proxy.getBbo(BTC_PERP);
        assertGt(bid, 0);
        assertGt(ask, 0);
        assertLe(bid, ask);
    }

    function test_getPosition_zeroByDefault() public view {
        assertEq(proxy.getPosition(BTC_PERP_16).szi, 0);
    }

    function test_getMarginSummary_seeded() public view {
        assertGt(proxy.getMarginSummary().accountValue, 0);
    }

    function test_changeOwner_emitsEvent() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(playerOwner);
        vm.expectEmit(true, false, false, false);
        emit PlayerProxy.OwnerChanged(newOwner);
        proxy.changeOwner(newOwner);
    }
}
