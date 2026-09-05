// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BrunoToken} from "../BrunoToken.sol";

import {IBruno} from "../interfaces/IBruno.sol";

import {IBrunoLpLocker} from "../interfaces/IBrunoLpLocker.sol";
import {IBrunoMevModule} from "../interfaces/IBrunoMevModule.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBrunoHook} from "../interfaces/IBrunoHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

abstract contract BrunoHook is BaseHook, Ownable, IBrunoHook {
    using TickMath for int24;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    uint24 public constant MAX_LP_FEE = 300_000; // LP fee capped at 30%
    uint256 public constant PROTOCOL_FEE_NUMERATOR = 200_000; // 20% of the imposed LP fee
    int128 public constant FEE_DENOMINATOR = 1_000_000; // Uniswap 100% fee

    uint24 public protocolFee;

    address public immutable factory;
    address public immutable weth;

    mapping(PoolId => bool) internal brunoIsToken0;
    mapping(PoolId => address) internal locker;

    // mev module pool variables
    uint256 public constant MAX_MEV_MODULE_DELAY = 2 minutes;
    mapping(PoolId => address) public mevModule;
    mapping(PoolId => bool) public mevModuleEnabled;
    mapping(PoolId => uint256) public poolCreationTimestamp;

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert OnlyFactory();
        }
        _;
    }

    constructor(address _poolManager, address _factory, address _weth)
        BaseHook(IPoolManager(_poolManager))
        Ownable(msg.sender)
    {
        factory = _factory;
        weth = _weth;
    }

    // function to for inheriting hooks to set fees in _beforeSwap hook
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        virtual
    {
        return;
    }

    // function to set the protocol fee to 20% of the lp fee
    function _setProtocolFee(uint24 lpFee) internal {
        protocolFee = uint24(uint256(lpFee) * PROTOCOL_FEE_NUMERATOR / uint128(FEE_DENOMINATOR));
    }

    // function to for inheriting hooks to set process data in during initialization flow
    function _initializePoolData(PoolKey memory poolKey, bytes memory poolData) internal virtual {
        return;
    }

    // function for the factory to initialize a pool
    function initializePool(
        address bruno,
        address pairedToken,
        int24 tickIfToken0IsBruno,
        int24 tickSpacing,
        address _locker,
        address _mevModule,
        bytes calldata poolData
    ) public onlyFactory returns (PoolKey memory) {
        // initialize the pool
        PoolKey memory poolKey =
            _initializePool(bruno, pairedToken, tickIfToken0IsBruno, tickSpacing, poolData);

        // set the locker config
        locker[poolKey.toId()] = _locker;

        // set the mev module
        mevModule[poolKey.toId()] = _mevModule;

        emit PoolCreatedFactory({
            pairedToken: pairedToken,
            bruno: bruno,
            poolId: poolKey.toId(),
            tickIfToken0IsBruno: tickIfToken0IsBruno,
            tickSpacing: tickSpacing,
            locker: _locker,
            mevModule: _mevModule
        });

        return poolKey;
    }

    // function to let anyone initialize a pool
    //
    // this is allow tokens not created by the factory to be used with this hook
    //
    // note: these pools do not have lp locker auto-claim or mev module functionality
    function initializePoolOpen(
        address bruno,
        address pairedToken,
        int24 tickIfToken0IsBruno,
        int24 tickSpacing,
        bytes calldata poolData
    ) public returns (PoolKey memory) {
        // if able, we prefer that weth is not the bruno as our hook fee will only
        // collect fees on the paired token
        if (bruno == weth) {
            revert WethCannotBeBruno();
        }

        PoolKey memory poolKey =
            _initializePool(bruno, pairedToken, tickIfToken0IsBruno, tickSpacing, poolData);

        emit PoolCreatedOpen(
            pairedToken, bruno, poolKey.toId(), tickIfToken0IsBruno, tickSpacing
        );

        return poolKey;
    }

    // common actions for initializing a pool
    function _initializePool(
        address bruno,
        address pairedToken,
        int24 tickIfToken0IsBruno,
        int24 tickSpacing,
        bytes calldata poolData
    ) internal virtual returns (PoolKey memory) {
        // ensure that the pool is not an ETH pool
        if (pairedToken == address(0) || bruno == address(0)) {
            revert ETHPoolNotAllowed();
        }

        // determine if bruno is token0
        bool token0IsBruno = bruno < pairedToken;

        // create the pool key
        PoolKey memory _poolKey = PoolKey({
            currency0: Currency.wrap(token0IsBruno ? bruno : pairedToken),
            currency1: Currency.wrap(token0IsBruno ? pairedToken : bruno),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        // Set the storage helpers
        brunoIsToken0[_poolKey.toId()] = token0IsBruno;

        // initialize the pool
        int24 startingTick = token0IsBruno ? tickIfToken0IsBruno : -tickIfToken0IsBruno;
        uint160 initialPrice = startingTick.getSqrtPriceAtTick();
        poolManager.initialize(_poolKey, initialPrice);

        // set the pool creation timestamp
        poolCreationTimestamp[_poolKey.toId()] = block.timestamp;

        // initialize other pool data
        _initializePoolData(_poolKey, poolData);

        return _poolKey;
    }

    // enable the mev module once the pool's deployment is complete
    //
    // note: this is done separate from the intiailization to allow for
    // extensions to take pool actions
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevModuleData)
        external
        onlyFactory
    {
        // initialize the mev module
        IBrunoMevModule(mevModule[poolKey.toId()]).initialize(poolKey, mevModuleData);

        // enable the mev module
        mevModuleEnabled[poolKey.toId()] = true;
    }

    function _runMevModule(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata mevModuleSwapData
    ) internal {
        // if the mev module is enabled and the pool is younger than 2 minutes, call it
        //
        // note: we have the 2 minute guard in case the sequencer environment
        // changes and the mev module breaks
        if (
            mevModuleEnabled[poolKey.toId()]
                && block.timestamp < poolCreationTimestamp[poolKey.toId()] + MAX_MEV_MODULE_DELAY
        ) {
            bool disableMevModule = IBrunoMevModule(mevModule[poolKey.toId()]).beforeSwap(
                poolKey, swapParams, brunoIsToken0[poolKey.toId()], mevModuleSwapData
            );

            // disable the mevModule if the module requests it
            if (disableMevModule) {
                mevModuleEnabled[poolKey.toId()] = false;
                emit MevModuleDisabled(poolKey.toId());
            }
        }
    }

    function _lpLockerFeeClaim(PoolKey calldata poolKey) internal {
        // if this wasn't initialized to claim fees, skip the claim
        if (locker[poolKey.toId()] == address(0)) {
            return;
        }

        // determine the token
        address token = brunoIsToken0[poolKey.toId()]
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        // trigger the fee claim
        IBrunoLpLocker(locker[poolKey.toId()]).collectRewardsWithoutUnlock(token);
    }

    function _hookFeeClaim(PoolKey calldata poolKey) internal {
        // determine the fee token
        Currency feeCurrency =
            brunoIsToken0[poolKey.toId()] ? poolKey.currency1 : poolKey.currency0;

        // get the fees stored from the previous swap in the pool manager
        uint256 fee = poolManager.balanceOf(address(this), feeCurrency.toId());

        if (fee == 0) {
            return;
        }

        // burn the fee
        poolManager.burn(address(this), feeCurrency.toId(), fee);

        // take the fee
        poolManager.take(feeCurrency, factory, fee);

        emit ClaimProtocolFees(Currency.unwrap(feeCurrency), fee);
    }

    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata mevModuleSwapData
    ) internal virtual override returns (bytes4, BeforeSwapDelta delta, uint24) {
        // set the fee for this swap
        _setFee(poolKey, swapParams);

        // trigger hook fee claim
        _hookFeeClaim(poolKey);

        // trigger the LP locker fee claim
        _lpLockerFeeClaim(poolKey);

        // run the mev module
        _runMevModule(poolKey, swapParams, mevModuleSwapData);

        // variables to determine how to collect protocol fee
        bool token0IsBruno = brunoIsToken0[poolKey.toId()];
        bool swappingForBruno = swapParams.zeroForOne != token0IsBruno;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount paired in, unspecified amount bruno out
        // want to: keep amountIn the same, take fee on amountIn
        // how: we modulate the specified amount being swapped DOWN, and
        // transfer the difference into the hook's account before making the swap
        if (isExactInput && swappingForBruno) {
            // since we're taking the protocol fee before the LP swap, we want to
            // take a slightly smaller amount to keep the taken LP/protocol fee at the 20% ratio,
            // this also helps us match the ExactOutput swappingForBruno scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 + protocolFee);
            int128 fee = int128(swapParams.amountSpecified * -int128(scaledProtocolFee) / 1e18);

            delta = toBeforeSwapDelta(fee, 0);
            poolManager.mint(
                address(this),
                token0IsBruno ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        // case: specified amount paired out, unspecified amount bruno in
        // want to: increase amountOut by fee and take it
        // how: we modulate the specified amount out UP, and transfer it
        // into the hook's account
        if (!isExactInput && !swappingForBruno) {
            // we increase the protocol fee here because we want to better match
            // the ExactOutput !swappingForBruno scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 - protocolFee);
            int128 fee = int128(swapParams.amountSpecified * int128(scaledProtocolFee) / 1e18);
            delta = toBeforeSwapDelta(fee, 0);

            poolManager.mint(
                address(this),
                token0IsBruno ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata mevModuleSwapData
    ) internal override returns (bytes4, int128 unspecifiedDelta) {
        // variables to determine how to collect protocol fee
        bool token0IsBruno = brunoIsToken0[poolKey.toId()];
        bool swappingForBruno = swapParams.zeroForOne != token0IsBruno;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount bruno in, unspecified amount paired out
        // want to: take fee on amount out
        // how: the change in unspecified delta is debited to the swaps account post swap,
        // in this case the amount out given to the swapper is decreased
        if (isExactInput && !swappingForBruno) {
            // grab non-bruno amount out
            int128 amountOut = token0IsBruno ? delta.amount1() : delta.amount0();
            // take fee from it
            unspecifiedDelta = amountOut * int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsBruno ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );
        }

        // case: specified amount bruno out, unspecified amount paired in
        // want to: take fee on amount in
        // how: the change in unspecified delta is debited to the swapper's account post swap,
        // in this case the amount taken from the swapper's account is increased
        if (!isExactInput && swappingForBruno) {
            // grab non-bruno amount in
            int128 amountIn = token0IsBruno ? delta.amount1() : delta.amount0();
            // take fee from amount int
            unspecifiedDelta = amountIn * -int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsBruno ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );
        }

        return (BaseHook.afterSwap.selector, unspecifiedDelta);
    }

    // prevent initializations that don't start via our initializePool functions
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert UnsupportedInitializePath();
    }

    // prevent liquidity adds during mev module operation
    function _beforeAddLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        if (
            mevModuleEnabled[poolKey.toId()]
                && block.timestamp < poolCreationTimestamp[poolKey.toId()] + MAX_MEV_MODULE_DELAY
        ) {
            revert MevModuleEnabled();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBrunoHook).interfaceId;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
