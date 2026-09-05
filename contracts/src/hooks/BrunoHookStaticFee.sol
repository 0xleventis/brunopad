// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BrunoHook} from "./BrunoHook.sol";
import {IBrunoHookStaticFee} from "./interfaces/IBrunoHookStaticFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract BrunoHookStaticFee is BrunoHook, IBrunoHookStaticFee {
    mapping(PoolId => uint24) public brunoFee;
    mapping(PoolId => uint24) public pairedFee;

    constructor(address _poolManager, address _factory, address _weth)
        BrunoHook(_poolManager, _factory, _weth)
    {}

    function _initializePoolData(PoolKey memory poolKey, bytes memory poolData) internal override {
        PoolStaticConfigVars memory _poolConfigVars = abi.decode(poolData, (PoolStaticConfigVars));

        if (_poolConfigVars.brunoFee > MAX_LP_FEE) {
            revert BrunoFeeTooHigh();
        }

        if (_poolConfigVars.pairedFee > MAX_LP_FEE) {
            revert PairedFeeTooHigh();
        }

        brunoFee[poolKey.toId()] = _poolConfigVars.brunoFee;
        pairedFee[poolKey.toId()] = _poolConfigVars.pairedFee;

        emit PoolInitialized(poolKey.toId(), _poolConfigVars.brunoFee, _poolConfigVars.pairedFee);
    }

    // set the LP fee according to the bruno/paired fee configuration
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        override
    {
        uint24 fee = swapParams.zeroForOne != brunoIsToken0[poolKey.toId()]
            ? pairedFee[poolKey.toId()]
            : brunoFee[poolKey.toId()];

        _setProtocolFee(fee);
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
    }
}
