// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {Bruno} from "../src/Bruno.sol";
import {BrunoFeeLocker} from "../src/BrunoFeeLocker.sol";
import {BrunoHookStaticFeeV2} from "../src/hooks/BrunoHookStaticFeeV2.sol";
import {BrunoPoolExtensionAllowlist} from "../src/hooks/BrunoPoolExtensionAllowlist.sol";
import {BrunoLpLockerFeeConversion} from "../src/lp-lockers/BrunoLpLockerFeeConversion.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// Deploys a fresh, Brunopad-owned instance of Clanker v4's protocol on Robinhood Chain (renamed
/// Bruno/Bruno* throughout — a real fork, MIT-licensed source, not a client of Clanker's own shared
/// deployment). Every address below was read directly off Clanker's own live contracts on Robinhood Chain
/// (public getters, verified via RPC — see this deployment's own investigation notes), not guessed or
/// copied from docs.
///
/// The MEV module is the one piece deliberately NOT redeployed (and NOT renamed — it's Clanker's own
/// contract, left as-is): BrunoMevDescendingFees (source name post-rename; the live instance below is
/// Clanker's own original deployment) has no constructor and no factory-binding at all (confirmed by
/// reading its source — no `onlyFactory`, no `Ownable`), so Clanker's own already-live instance is safe
/// and correct to reuse directly via `setMevModule`.
///
/// Run as a dry run first (no --broadcast) to confirm this simulates cleanly before spending real gas:
///   forge script script/DeployBrunopad.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com -vvvv
/// Then for the real deployment (run by whoever holds OWNER's private key):
///   forge script script/DeployBrunopad.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
///     --broadcast --private-key $PRIVATE_KEY -vvvv
contract DeployBrunopad is Script {
    // Permanent owner of the new factory/fee locker/allowlist — controls which hooks/lockers/MEV modules
    // are ever enabled, and where protocol-level fees (Bruno.sol's claimTeamFees) go. Set explicitly by
    // the project owner, not derived from whoever happens to run this script.
    address constant OWNER = 0xdb5FbCd6fb5C46F6F52B62ACAE333a3AE0b0F108;

    // Real, live Uniswap v4 + Clanker-ecosystem infrastructure on Robinhood Chain (chain id 4663) — generic
    // shared infra, not Clanker-specific, so safe to reuse as-is. Read directly via RPC from Clanker's own
    // deployed LP locker (0xE4910b09709423aFafD995dD76D8A81CF9134A09) and hook
    // (0x48B8F6AD3A1b4aA477314c9a23035b8F84dDe8cc) — both `public immutable`, so this is ground truth, not
    // an assumption.
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // Clanker's own already-live MEV module — reused directly, see this contract's header comment for why
    // that's safe (it's stateless and has no factory binding at all).
    address constant EXISTING_MEV_MODULE = 0xEA1Fe197dF140e5d88fC6B49f2d21Ea05092299e;

    // The canonical, permissionless CREATE2 deployer proxy present on effectively every EVM chain — what
    // `forge script`'s `new X{salt: ...}(...)` actually deploys through when broadcasting, and what
    // HookMiner.find's `deployer` param must match for the mined address to be correct.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        vm.startBroadcast();

        Bruno factory = new Bruno(OWNER);
        console2.log("Factory:", address(factory));

        BrunoFeeLocker feeLocker = new BrunoFeeLocker(OWNER);
        console2.log("Fee locker:", address(feeLocker));

        BrunoPoolExtensionAllowlist allowlist = new BrunoPoolExtensionAllowlist(OWNER);
        console2.log("Pool extension allowlist:", address(allowlist));

        // Uniswap v4 requires a hook's own address to encode which callbacks it implements in its low
        // bits — mine a CREATE2 salt that produces such an address for BrunoHookStaticFeeV2's exact
        // permission set (read directly from its own getHookPermissions() override) before deploying it.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory hookConstructorArgs = abi.encode(POOL_MANAGER, address(factory), address(allowlist), WETH);
        (address predictedHookAddress, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER, flags, type(BrunoHookStaticFeeV2).creationCode, hookConstructorArgs
        );

        BrunoHookStaticFeeV2 hook =
            new BrunoHookStaticFeeV2{salt: hookSalt}(POOL_MANAGER, address(factory), address(allowlist), WETH);
        require(address(hook) == predictedHookAddress, "hook address mismatch");
        console2.log("Hook (static fee v2):", address(hook));

        BrunoLpLockerFeeConversion locker = new BrunoLpLockerFeeConversion(
            OWNER, address(factory), address(feeLocker), POSITION_MANAGER, PERMIT2, UNIVERSAL_ROUTER, POOL_MANAGER
        );
        console2.log("LP locker:", address(locker));

        // Wire it all together on the new factory, then let the new locker deposit into the new fee locker.
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setMevModule(EXISTING_MEV_MODULE, true);
        feeLocker.addDepositor(address(locker));

        // The constructor deliberately starts the factory `deprecated` ("only non-originating token
        // deployments are enabled before initialization" — its own comment) — real bug hit live: a real
        // deployToken call against a freshly-deployed-but-not-yet-activated factory reverts with
        // Deprecated(), confirmed by decoding the exact revert selector against every error IBruno.sol
        // declares. This is the step that actually turns launches on.
        factory.setDeprecated(false);

        vm.stopBroadcast();

        console2.log("\n=== Brunopad deployment summary ===");
        console2.log("Owner:              ", OWNER);
        console2.log("Factory:            ", address(factory));
        console2.log("Fee locker:         ", address(feeLocker));
        console2.log("Pool ext allowlist: ", address(allowlist));
        console2.log("Hook (static v2):   ", address(hook));
        console2.log("LP locker:          ", address(locker));
        console2.log("MEV module (reused):", EXISTING_MEV_MODULE);
    }
}
