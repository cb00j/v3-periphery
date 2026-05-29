// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol';
import '@uniswap/v3-core/contracts/libraries/TickMath.sol';

import '../libraries/PoolAddress.sol';
import '../libraries/CallbackValidation.sol';
import '../libraries/LiquidityAmounts.sol';

import './PeripheryPayments.sol';
import './PeripheryImmutableState.sol';

/// @title Liquidity management functions
/// @notice Internal functions for safely managing liquidity in Uniswap V3
abstract contract LiquidityManagement is IUniswapV3MintCallback, PeripheryImmutableState, PeripheryPayments {
    struct MintCallbackData {
        PoolAddress.PoolKey poolKey;
        address payer;
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);

        if (amount0Owed > 0) pay(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) pay(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
    }

    struct AddLiquidityParams {
        address token0; // token0 的地址
        address token1; // token1 的地址
        uint24 fee; // 交易费率档位
        address recipient; // 流动性的所属人地址，即仓位的所有权
        int24 tickLower; // 流动性的价格下限（以 token0 计价），这里传入的是 tick index
        int24 tickUpper; // 流动性的价格上线（以 token0 计价），这里传入的是 tick index
        uint256 amount0Desired; // 期望投入的 token0 数量，注意这里是期望投入的数量（前端页面填写的数量），而不是实际提供的数量，因为实际提供的数量会受到价格波动的影响，可能会比期望投入的数量少
        uint256 amount1Desired; // 期望投入的 token1 数量
        uint256 amount0Min; // 提供的 token0下限数
        uint256 amount1Min; // 提供的 token1下限数，如果合约最终扣的 token0 < amount0Min 或 token1 < amount1Min，整笔交易 revert，滑点保护机制
    }

    /// @notice Add liquidity to an initialized pool
    function addLiquidity(
        AddLiquidityParams memory params
    ) internal returns (uint128 liquidity, uint256 amount0, uint256 amount1, IUniswapV3Pool pool) {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee
        });

        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));

        // compute the liquidity amount
        // 计算流动性L
        {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, // 当前价格
                sqrtRatioAX96, // 做市价格下限
                sqrtRatioBX96, // 做市价格上限
                params.amount0Desired,
                params.amount1Desired
            );
        }

        (amount0, amount1) = pool.mint(
            params.recipient,
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );

        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Price slippage check');
    }
}
