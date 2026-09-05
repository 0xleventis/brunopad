// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Bruno} from "./Bruno.sol";
import {BrunoB20Deployer} from "./utils/BrunoB20Deployer.sol";

/// @notice Base-mainnet variant of Bruno. Every pool-creation/LP-locking/fee-split/extension/MEV-module
///         code path is inherited unchanged from Bruno.sol (deliberately kept as a separate deployed
///         contract from the Robinhood Chain factory rather than a shared/upgraded one, so this never
///         touches the already-live, already-verified Robinhood Chain deployment). The only difference
///         is _createToken, overridden to mint through Base's own B-20 standard factory instead of
///         deploying BrunoToken.sol bytecode — see utils/BrunoB20Deployer.sol for why, and for what's
///         traded away (BrunoToken's own admin/image/metadata/verify() surface) to get every token a
///         real `0xb20...` address.
contract BrunoBase is Bruno {
    constructor(address owner_) Bruno(owner_) {}

    function _createToken(TokenConfig memory tokenConfig, uint256 supply)
        internal
        override
        returns (address tokenAddress)
    {
        tokenAddress = BrunoB20Deployer.deployToken(tokenConfig, supply);
    }
}
