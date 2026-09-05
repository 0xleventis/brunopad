// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BrunoToken} from "../BrunoToken.sol";
import {IBruno} from "../interfaces/IBruno.sol";

/// @notice Bruno Token Launcher
library BrunoDeployer {
    function deployToken(IBruno.TokenConfig memory tokenConfig, uint256 supply)
        external
        returns (address tokenAddress)
    {
        BrunoToken token = new BrunoToken{
            salt: keccak256(abi.encode(tokenConfig.tokenAdmin, tokenConfig.salt))
        }(
            tokenConfig.name,
            tokenConfig.symbol,
            supply,
            tokenConfig.tokenAdmin,
            tokenConfig.image,
            tokenConfig.metadata,
            tokenConfig.context,
            tokenConfig.originatingChainId
        );
        tokenAddress = address(token);
    }
}
