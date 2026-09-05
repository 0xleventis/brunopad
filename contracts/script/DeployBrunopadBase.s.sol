// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

import {BrunoBase} from "../src/BrunoBase.sol";
import {BrunoFeeLocker} from "../src/BrunoFeeLocker.sol";
import {BrunoHookStaticFeeV2} from "../src/hooks/BrunoHookStaticFeeV2.sol";
import {BrunoPoolExtensionAllowlist} from "../src/hooks/BrunoPoolExtensionAllowlist.sol";
import {BrunoLpLockerFeeConversion} from "../src/lp-lockers/BrunoLpLockerFeeConversion.sol";
import {BrunoMevDescendingFees} from "../src/mev-modules/BrunoMevDescendingFees.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// Deploys Brunopad's own instance of the protocol on Base mainnet (chain id 8453), using BrunoBase (not
/// Bruno) as the factory so every token minted here gets a real `0xb20...` address via Base's own B-20
/// standard factory — see BrunoBase.sol/BrunoB20Deployer.sol for why. Everything else (hook, pool
/// extension allowlist, LP locker, MEV module) is the exact same contract used on Robinhood Chain,
/// freshly deployed here against Base's own real Uniswap v4 infrastructure — this deployment is fully
/// independent of the Robinhood Chain one (separate owner-controlled instance, doesn't touch it).
///
/// Infra addresses below are Uniswap's own official Base mainnet deployment (developers.uniswap.org/docs
/// /protocols/v4/deployments), each confirmed to have real, live bytecode via a direct eth_getCode call
/// before being hardcoded here — not copied blind. WETH is Base's own canonical predeploy.
///
/// The MEV module is deployed fresh here (BrunoMevDescendingFees has no constructor and no
/// factory-binding, exactly like the instance reused as-is on Robinhood Chain) rather than reusing either
/// of Clanker's own two real MEV module addresses on Base — those aren't confirmed to be the same
/// DescendingFees behavior this contract expects (Base's clanker-sdk config lists `mevModule` and
/// `mevModuleV2` with no `mevDescendingFees` flag, unlike Robinhood Chain's entry which has one), and
/// deploying our own keeps this fully self-contained rather than depending on guessing which of two
/// third-party addresses is the right type.
///
/// Run as a dry run first (no --broadcast) to confirm this simulates cleanly before spending real gas:
///   forge script script/DeployBrunopadBase.s.sol --rpc-url https://mainnet.base.org --sender 0xdb5FbCd6fb5C46F6F52B62ACAE333a3AE0b0F108 -vvvv
/// Then for the real deployment (run by whoever holds OWNER's private key):
///   forge script script/DeployBrunopadBase.s.sol --rpc-url https://mainnet.base.org \
///     --broadcast --private-key $PRIVATE_KEY -vvvv
contract DeployBrunopadBase is Script {
    // Same permanent owner as the Robinhood Chain deployment — controls which hooks/lockers/MEV modules
    // are enabled on this (separate) Base instance, and where this instance's protocol-level fees go.
    address constant OWNER = 0xdb5FbCd6fb5C46F6F52B62ACAE333a3AE0b0F108;

    // Real, live Uniswap v4 infrastructure on Base mainnet — verified via a direct eth_getCode call
    // against each address before being hardcoded here (all returned real, substantial bytecode).
    address constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // The canonical, permissionless CREATE2 deployer proxy present on effectively every EVM chain
    // (including Base) — what `forge script`'s `new X{salt: ...}(...)` actually deploys through when
    // broadcasting, and what HookMiner.find's `deployer` param must match for the mined address to be
    // correct.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Same starting tick the frontend has always sent for a WETH-paired launch (app/brunoFactory.ts's
    // STARTING_TICK) — registering it here preserves that exact existing behavior. Bruno.sol now requires
    // pairedToken to be registered before initializing a pool (see IBruno.QuoteInfo's own header comment)
    // — this fresh Base factory starts with an empty registry, so without this call every deployToken
    // would revert QuoteNotRegistered() from launch one.
    int24 constant WETH_START_TICK = -230400;

    function run() external {
        vm.startBroadcast();

        BrunoBase factory = new BrunoBase(OWNER);
        console2.log("Factory (Base, B-20):", address(factory));

        BrunoFeeLocker feeLocker = new BrunoFeeLocker(OWNER);
        console2.log("Fee locker:", address(feeLocker));

        BrunoPoolExtensionAllowlist allowlist = new BrunoPoolExtensionAllowlist(OWNER);
        console2.log("Pool extension allowlist:", address(allowlist));

        // Same hook contract as Robinhood Chain, mined fresh for its own CREATE2 address on this chain —
        // Uniswap v4 requires a hook's own address to encode which callbacks it implements in its low
        // bits, so the mined salt isn't portable across chains/deployer instances.
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

        BrunoMevDescendingFees mevModule = new BrunoMevDescendingFees();
        console2.log("MEV module (fresh):", address(mevModule));

        // Wire it all together on the new factory, then let the new locker deposit into the new fee locker.
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setMevModule(address(mevModule), true);
        factory.setQuote(WETH, true, WETH_START_TICK);
        feeLocker.addDepositor(address(locker));

        // Same real bug as the Robinhood Chain deployment: the constructor starts the factory
        // `deprecated` until explicitly turned off — this is the step that actually turns launches on.
        factory.setDeprecated(false);

        vm.stopBroadcast();

        console2.log("\n=== Brunopad Base deployment summary ===");
        console2.log("Owner:              ", OWNER);
        console2.log("Factory:            ", address(factory));
        console2.log("Fee locker:         ", address(feeLocker));
        console2.log("Pool ext allowlist: ", address(allowlist));
        console2.log("Hook (static v2):   ", address(hook));
        console2.log("LP locker:          ", address(locker));
        console2.log("MEV module (fresh): ", address(mevModule));
    }
}
