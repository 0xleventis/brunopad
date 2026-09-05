// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBruno} from "../interfaces/IBruno.sol";
import {IB20Factory} from "../interfaces/IB20Factory.sol";

/// @notice Bruno Token Launcher — Base variant. Mints through Base's own B-20 standard factory instead
///         of deploying BrunoToken.sol bytecode, so every token launched via BrunoBase.sol gets a real
///         `0xb20...` address. See BrunoDeployer.sol for the Robinhood Chain equivalent (untouched,
///         still used there) — the two aren't interchangeable: B-20 tokens run Base's own canonical
///         token implementation, not BrunoToken.sol, so they don't carry BrunoToken's own
///         admin/image/metadata/verify() surface (tokenConfig.image/metadata/context are simply unused
///         here — the frontend's own off-chain feed already carries that data separately). In exchange,
///         every token gets a real, hard-to-spoof branded address (Base's own opt-in standard — see
///         IB20Factory.sol, a real permissionless system contract at a fixed address, not something this
///         app deploys or controls).
///
/// Both the params encoding and the admin model below were corrected against a real, live eth_call
/// against Base mainnet (not just read off Basescan's interface comments, which turned out to be
/// insufficient to reproduce byte-for-byte): `params` isn't a flat `abi.encode` of 5 loose values — it's
/// `abi.encode` of ONE tuple-typed struct value, which is what actually produces the leading offset word
/// real onchain calls carry (confirmed by decoding the exact bytes of a real, successful createB20 call,
/// tx 0x4ef7ec1abc17542bcace04ad4f8610a71719c04c766b8cee67b02ef553eaa75a, "Paprik"/PPR — flat encoding
/// reverts with "ABI decoding failed: buffer overrun while deserializing"). That same real transaction
/// also used `initialAdmin = address(0)` (admin-less): the bootstrap-mint privilege belongs to whoever
/// calls createB20 (msg.sender of THIS call, i.e. this factory, in this library's delegatecall context)
/// for the duration of this one transaction — it isn't derived from `initialAdmin` at all. Admin-less is
/// strictly better than granting the factory a lingering admin role: same one-shot mint capability, but
/// the resulting token can never have a role holder again afterward — the same "fixed supply forever, no
/// admin at all" guarantee BrunoToken.sol gets from never having a mint function, not just from hitting a
/// supply cap.
library BrunoB20Deployer {
    address constant B20_FACTORY = 0xB20f000000000000000000000000000000000000;
    uint8 constant PARAMS_VERSION = 1;
    uint8 constant DECIMALS = 18;

    struct AssetParams {
        uint8 version;
        string name;
        string symbol;
        address initialAdmin;
        uint8 decimals;
    }

    function deployToken(IBruno.TokenConfig memory tokenConfig, uint256 supply)
        external
        returns (address tokenAddress)
    {
        // Same salt derivation as BrunoDeployer.sol, so a given (tokenAdmin, tokenConfig.salt) pair
        // predicts the same way regardless of which chain/deployer ends up handling it.
        bytes32 salt = keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt));

        bytes memory params = abi.encode(
            AssetParams({
                version: PARAMS_VERSION,
                name: tokenConfig.name,
                symbol: tokenConfig.symbol,
                initialAdmin: address(0),
                decimals: DECIMALS
            })
        );

        // Mint recipient is address(this) — in this library's delegatecall context that's the calling
        // factory (Bruno.sol/BrunoBase.sol), not tokenConfig.tokenAdmin. Mirrors BrunoToken.sol's own
        // constructor, which mints the full supply to msg.sender (the factory) rather than to the
        // token's actual admin — the factory splits it out to creator/treasury/LP afterward either way.
        bytes[] memory initCalls = new bytes[](2);
        initCalls[0] = abi.encodeWithSignature("updateSupplyCap(uint256)", supply);
        initCalls[1] = abi.encodeWithSignature("mint(address,uint256)", address(this), supply);

        tokenAddress = IB20Factory(B20_FACTORY).createB20(
            IB20Factory.B20Variant.ASSET, salt, params, initCalls
        );
    }
}
