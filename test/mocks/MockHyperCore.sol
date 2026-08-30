// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BaseSimulatorTest} from "@hyper-evm-lib/test/BaseSimulatorTest.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";
import {MockUSDC} from "./MockUSDC.sol";

abstract contract MockHyperCore is BaseSimulatorTest {
    uint32 constant BTC_PERP = 0;
    uint16 constant BTC_PERP_16 = 0;
    uint64 constant BTC_PRICE = 80_000_000;

    function setUp() public virtual override {
        hyperCore = CoreSimulatorLib.init();
        hyperCore.setUseRealL1Read(false);

        _registerBtcPerp();
        _mockPrecompiles();
        _deployMockUsdc();
    }

    function _registerBtcPerp() internal {
        hyperCore.registerPerpAssetInfo(
            0,
            PrecompileLib.PerpAssetInfo({
                coin: "BTC", marginTableId: 0, szDecimals: 5, maxLeverage: 50, onlyIsolated: false
            })
        );
        hyperCore.setMarkPx(0, BTC_PRICE);
    }

    function _mockPrecompiles() internal {
        // Oracle price — no setter exists on HyperCore
        vm.mockCall(HLConstants.ORACLE_PX_PRECOMPILE_ADDRESS, abi.encode(uint32(0)), abi.encode(uint64(BTC_PRICE)));

        // BBO — not simulated in offline mode
        vm.mockCall(
            HLConstants.BBO_PRECOMPILE_ADDRESS,
            abi.encode(uint64(0)),
            abi.encode(uint64((BTC_PRICE * 999) / 1000), uint64((BTC_PRICE * 1001) / 1000))
        );
    }

    function _deployMockUsdc() internal {
        vm.etch(HLConstants.usdc(), address(new MockUSDC()).code);
    }
}
