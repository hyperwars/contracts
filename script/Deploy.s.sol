// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GameMaster} from "../src/GameMaster.sol";
import {GameRoomFactory} from "../src/GameRoomFactory.sol";
import {DefaultGameRoom} from "../src/DefaultGameRoom.sol";
import {PlayerProxy} from "../src/PlayerProxy.sol";

/**
 * First deploy script for the hyperwars contracts. Codifies the choreography
 * referenced by ADR 0002 + ADR 0006 + `contracts/plan.md`:
 *
 *   1. Deploy PlayerProxy implementation (cloned per-player-per-room).
 *   2. Deploy DefaultGameRoom implementation (cloned per-room by the factory).
 *   3. Deploy GameMaster implementation.
 *   4. Deploy ERC1967Proxy wrapping (3), initialized with owner/treasury + PlayerProxy impl.
 *   5. Deploy GameRoomFactory bound to the DefaultGameRoom impl.
 *   6. As GameMaster owner, registerFactory(factory).
 *
 * Revenue is collected exclusively through Hyperliquid builder fees set on each
 * PlayerProxy at init. No protocol or maker fee is deducted at settlement.
 *
 * Driven entirely by env so the same script services the local anvil fork
 * (docker-compose `contracts-deploy` service) and future testnet/mainnet runs.
 *
 * Env vars (all optional — defaults match a local-fork happy path):
 *   OWNER                  — GameMaster owner. Default: msg.sender (broadcast key).
 *   PROTOCOL_TREASURY      — Builder-fee recipient on Hyperliquid. Default: msg.sender.
 *   BUILDER_FEE_RECIPIENT  — Factory-wide builder-fee recipient. Empty/unset means
 *                            address(0), so GameMaster.createRoom falls back to protocolTreasury.
 *   SKIP_REGISTER_FACTORY  — If "true", skips step 6 (use when owner != broadcast key).
 *   MIN_TRADING_BALANCE    — Min per-player trading balance to allow a room. Default: 2_000_000 (2 USDC).
 *   MAX_PLAYERS            — Factory cap on config.maxPlayers. Default: 10.
 *   MAX_ASSETS             — Factory cap on allowedAssets length. Default: 5.
 *   MAX_ROUND_DURATION     — Factory cap on config.maxRoundDuration (blocks). Default: 3600.
 *
 * Output:
 *   - Standard forge broadcast log at broadcast/Deploy.s.sol/<chainid>/run-latest.json
 *   - Console-logged address summary the entrypoint shell extracts with jq into
 *     /deployments/local.json (consumed by backend via loadLocalAddresses).
 */
contract Deploy is Script {
    struct DeployConfig {
        address owner;
        address protocolTreasury;
        address builderFeeRecipient;
        bool skipRegisterFactory;
        uint256 minTradingBalance;
        uint256 maxPlayers;
        uint256 maxAssets;
        uint256 maxRoundDuration;
    }

    struct Deployed {
        address gameMasterProxy;
        address gameRoomFactory;
        address defaultGameRoomImpl;
        address playerProxyImpl;
    }

    function readConfig(address deployer) internal view returns (DeployConfig memory cfg) {
        cfg.owner = vm.envOr("OWNER", deployer);
        cfg.protocolTreasury = vm.envOr("PROTOCOL_TREASURY", deployer);
        cfg.builderFeeRecipient = vm.envOr("BUILDER_FEE_RECIPIENT", address(0));
        cfg.skipRegisterFactory = vm.envOr("SKIP_REGISTER_FACTORY", false);
        cfg.minTradingBalance = vm.envOr("MIN_TRADING_BALANCE", uint256(2_000_000));
        cfg.maxPlayers = vm.envOr("MAX_PLAYERS", uint256(10));
        cfg.maxAssets = vm.envOr("MAX_ASSETS", uint256(5));
        cfg.maxRoundDuration = vm.envOr("MAX_ROUND_DURATION", uint256(3600));
    }

    function deployAll(DeployConfig memory cfg) internal returns (Deployed memory out) {
        out.playerProxyImpl = address(new PlayerProxy());
        out.defaultGameRoomImpl = address(new DefaultGameRoom());

        GameMaster gameMasterImpl = new GameMaster();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(gameMasterImpl),
            abi.encodeCall(
                GameMaster.initialize, (cfg.owner, cfg.protocolTreasury, out.playerProxyImpl, cfg.minTradingBalance)
            )
        );
        out.gameMasterProxy = address(proxy);

        out.gameRoomFactory = address(
            new GameRoomFactory(
                out.defaultGameRoomImpl, cfg.builderFeeRecipient, cfg.maxPlayers, cfg.maxAssets, cfg.maxRoundDuration
            )
        );
    }

    function logDeployed(DeployConfig memory cfg, Deployed memory out, bool registered) internal pure {
        console.log("=== hyperwars deploy ===");
        console.log("gameMasterProxy       :", out.gameMasterProxy);
        console.log("gameRoomFactory       :", out.gameRoomFactory);
        console.log("defaultGameRoomImpl   :", out.defaultGameRoomImpl);
        console.log("playerProxyImpl       :", out.playerProxyImpl);
        console.log("owner                 :", cfg.owner);
        console.log("protocolTreasury      :", cfg.protocolTreasury);
        console.log("builderFeeRecipient   :", cfg.builderFeeRecipient);
        console.log("minTradingBalance     :", cfg.minTradingBalance);
        console.log("maxPlayers            :", cfg.maxPlayers);
        console.log("maxAssets             :", cfg.maxAssets);
        console.log("maxRoundDuration      :", cfg.maxRoundDuration);
        console.log("registered factory    :", registered);
    }

    function run() external returns (Deployed memory out) {
        address deployer = msg.sender;
        DeployConfig memory cfg = readConfig(deployer);

        vm.startBroadcast();
        out = deployAll(cfg);

        bool register = !cfg.skipRegisterFactory && cfg.owner == deployer;
        if (register) {
            GameMaster(out.gameMasterProxy).registerFactory(out.gameRoomFactory);
        }
        vm.stopBroadcast();

        logDeployed(cfg, out, register);
    }
}
