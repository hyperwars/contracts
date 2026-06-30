// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
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
    uint64 constant SEED_SPOT_USDC = 200e6;

    function setUp() public override {
        super.setUp();

        mockGameRoom = new MockGameRoom();
        implementation = new PlayerProxy();
        proxy = _freshProxy("playerOwner");
    }

    function _freshProxy(string memory label) internal returns (PlayerProxy) {
        address clone = Clones.clone(address(implementation));
        PlayerProxy fresh = PlayerProxy(payable(clone));
        hyperCore.forceAccountActivation(address(fresh));
        hyperCore.forcePerpBalance(address(fresh), SEED_PERP_USD);
        hyperCore.forceSpotBalance(address(fresh), HLConstants.USDC_TOKEN_INDEX, SEED_SPOT_USDC);
        fresh.initialize(makeAddr(label), address(mockGameRoom));
        return fresh;
    }

    function _coreWriterLogCount(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == CORE_WRITER) ++count;
        }
    }

    function test_initialize_setsOwnerAndGameRoom() public {
        assertEq(proxy.owner(), makeAddr("playerOwner"));
        assertEq(proxy.gameRoom(), address(mockGameRoom));
    }

    function test_initialize_revertsOnReInit() public {
        vm.expectRevert(PlayerProxy.AlreadyInitialized.selector);
        proxy.initialize(playerOwner, address(mockGameRoom));
    }

    // initialize() must not touch CoreWriter: Core silently drops addApiWallet for an account it
    // does not yet know (issue #52). Registration is deferred to authorizeAgent().
    function test_initialize_emitsNoCoreWriterActions() public {
        vm.recordLogs();
        _freshProxy("freshInit");
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 0);
    }

    function test_activate_enqueuesTransferToPerp() public {
        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        proxy.activate(uint64(50e6), address(0), 0);
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 1);
        CoreSimulatorLib.nextBlock();
    }

    function test_activate_approvesBuilderFee() public {
        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        proxy.activate(uint64(50e6), builderAddr, 5);
        // approveBuilderFee + transferUsdClass.
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 2);
        CoreSimulatorLib.nextBlock();
    }

    function test_activate_skipsBuilderFeeWhenZeroAddress() public {
        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        proxy.activate(uint64(50e6), address(0), 5);
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 1);
        CoreSimulatorLib.nextBlock();
    }

    function test_activate_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.activate(uint64(50e6), builderAddr, builderFeeRate);
    }

    function test_activate_revertsForOwner() public {
        vm.prank(makeAddr("playerOwner"));
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.activate(uint64(50e6), builderAddr, builderFeeRate);
    }

    function test_authorizeAgent_enqueuesApiWallet() public {
        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        proxy.authorizeAgent();
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 1);
        CoreSimulatorLib.nextBlock();
    }

    function test_authorizeAgent_emits() public {
        vm.expectEmit(true, false, false, false);
        emit PlayerProxy.AgentAuthorized(makeAddr("playerOwner"));
        vm.prank(address(mockGameRoom));
        proxy.authorizeAgent();
    }

    function test_authorizeAgent_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.authorizeAgent();
    }

    function test_revokeAgent_enqueuesApiWallet() public {
        vm.recordLogs();
        vm.prank(address(mockGameRoom));
        proxy.revokeAgent();
        assertEq(_coreWriterLogCount(vm.getRecordedLogs()), 1);
        CoreSimulatorLib.nextBlock();
    }

    function test_revokeAgent_emits() public {
        vm.expectEmit(true, false, false, false);
        emit PlayerProxy.AgentRevoked(makeAddr("playerOwner"));
        vm.prank(address(mockGameRoom));
        proxy.revokeAgent();
    }

    function test_revokeAgent_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.revokeAgent();
    }

    function test_moveMarginToSpot_emits() public {
        vm.prank(address(mockGameRoom));
        vm.expectEmit(false, false, false, true);
        emit PlayerProxy.MarginMovedToSpot(50e6);
        proxy.moveMarginToSpot(50e6);
    }

    function test_moveMarginToSpot_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.moveMarginToSpot(50e6);
    }

    function test_sendUsdc_emits() public {
        vm.prank(address(mockGameRoom));
        vm.expectEmit(true, false, false, true);
        emit PlayerProxy.UsdcSent(stranger, 25e6);
        proxy.sendUsdc(stranger, 25e6);
    }

    function test_sendUsdc_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.sendUsdc(stranger, 25e6);
    }

    function test_forceCloseAll_fromGameRoom_noRevert() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(address(mockGameRoom));
        proxy.forceCloseAll(assets); // No revert = success
    }

    function test_forceCloseAll_revertsForStranger() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = BTC_PERP;
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.forceCloseAll(assets);
    }

    function test_withdraw_sendsSpotToOwner() public {
        PlayerProxy p = _freshProxy("withdrawer");
        address owner = makeAddr("withdrawer");
        hyperCore.forceAccountActivation(owner);

        vm.prank(owner);
        p.withdraw();
        CoreSimulatorLib.nextBlock();

        assertEq(PrecompileLib.spotBalance(owner, HLConstants.USDC_TOKEN_INDEX).total, SEED_SPOT_USDC);
        assertEq(PrecompileLib.spotBalance(address(p), HLConstants.USDC_TOKEN_INDEX).total, 0);
    }

    function test_withdraw_revertsWhenLocked() public {
        mockGameRoom.setWithdrawAllowed(false);
        vm.prank(makeAddr("playerOwner"));
        vm.expectRevert(PlayerProxy.WithdrawLocked.selector);
        proxy.withdraw();
    }

    function test_withdraw_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        proxy.withdraw();
    }

    function _keyedProxy() internal returns (PlayerProxy p, address ownerAddr, uint256 pk) {
        (ownerAddr, pk) = makeAddrAndKey("exitOwner");
        address clone = Clones.clone(address(implementation));
        p = PlayerProxy(payable(clone));
        hyperCore.forceAccountActivation(address(p));
        hyperCore.forcePerpBalance(address(p), SEED_PERP_USD);
        hyperCore.forceSpotBalance(address(p), HLConstants.USDC_TOKEN_INDEX, SEED_SPOT_USDC);
        p.initialize(ownerAddr, address(mockGameRoom));
    }

    function _signExit(PlayerProxy p, address ownerAddr, uint256 pk, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("HyperwarsPlayerProxy")),
                keccak256(bytes("1")),
                block.chainid,
                address(p)
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(keccak256("Exit(address owner,uint256 deadline)"), ownerAddr, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_exit_revertsWhenExpired() public {
        (PlayerProxy p, address ownerAddr, uint256 pk) = _keyedProxy();
        bytes memory sig = _signExit(p, ownerAddr, pk, 0);
        vm.expectRevert(PlayerProxy.ExitExpired.selector);
        p.exit(0, sig);
    }

    function test_exit_revertsForBadSignature() public {
        (PlayerProxy p, address ownerAddr,) = _keyedProxy();
        (, uint256 attackerPk) = makeAddrAndKey("attacker");
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signExit(p, ownerAddr, attackerPk, deadline);
        vm.expectRevert(PlayerProxy.Unauthorized.selector);
        p.exit(deadline, sig);
    }

    function test_exit_revertsWhenLocked() public {
        (PlayerProxy p, address ownerAddr, uint256 pk) = _keyedProxy();
        mockGameRoom.setWithdrawAllowed(false);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signExit(p, ownerAddr, pk, deadline);
        vm.expectRevert(PlayerProxy.WithdrawLocked.selector);
        p.exit(deadline, sig);
    }

    // Relayer (not the owner) drives the two-hop exit: perp margin -> spot, then spot -> owner.
    function test_exit_relayerDrivesTwoHopToOwner() public {
        (PlayerProxy p, address ownerAddr, uint256 pk) = _keyedProxy();
        hyperCore.forceAccountActivation(ownerAddr);
        address relayer = makeAddr("relayer");
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signExit(p, ownerAddr, pk, deadline);

        vm.prank(relayer);
        p.exit(deadline, sig); // perp -> spot
        CoreSimulatorLib.nextBlock();

        vm.prank(relayer);
        p.exit(deadline, sig); // spot -> owner
        CoreSimulatorLib.nextBlock();

        assertGt(PrecompileLib.spotBalance(ownerAddr, HLConstants.USDC_TOKEN_INDEX).total, SEED_SPOT_USDC);
        assertEq(PrecompileLib.spotBalance(address(p), HLConstants.USDC_TOKEN_INDEX).total, 0);
        assertEq(PrecompileLib.withdrawable(address(p)), 0);
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
}
