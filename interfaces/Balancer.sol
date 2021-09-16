// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";



interface IBalancerPoolToken {
    function transfer(address recipient, uint256 amount) external;

    function approve(address spender, uint256 amount) external;

    function bPool() external view returns (address);

    function balanceOf(address account) external view returns (uint256 balance);

    function whitelistLiquidityProvider(address provider) external;

    function removeWhitelistedLiquidityProvider(address provider) external;

    function gradualUpdate() external view returns (uint256 startBlock, uint256 endBlock);

    function updateWeight(address token, uint256 newWeight) external;

    function updateWeightsGradually(uint256[] calldata newWeights, uint256 startBlock, uint256 endBlock) external;

    function pokeWeights() external;

    function setController(address) external;

    function setPublicSwap(bool isPublic) external;

    function setSwapFee(uint256 fee) external;

    function joinPool(uint poolAmountOut, uint[] calldata maxAmountsIn) external;

    function totalSupply() external view returns (uint256);

    function exitPool(uint poolAmountIn, uint[] calldata minAmountsOut) external;

    function minimumWeightChangeBlockPeriod() external view returns (uint256);

    function joinswapExternAmountIn(address tokenIn, uint tokenAmountIn, uint minPoolAmountOut) external returns (uint256 poolAmountOut);

    function exitswapExternAmountOut(address tokenOut, uint256 tokenAmountOut, uint256 maxPoolAmountIn) external returns (uint256 poolAmountIn);
}

interface IBalancerPool {
    function getSwapFee() external view returns (uint256);

    function getBalance(address token) external view returns (uint);

    function getTotalDenormalizedWeight() external view returns (uint256);

    function getDenormalizedWeight(address token) external view returns (uint256);

    function getNormalizedWeight(address token) external view returns (uint256);

    function getCurrentTokens() external view returns (address[] calldata);

    function swapExactAmountIn(
        address tokenIn,
        uint tokenAmountIn,
        address tokenOut,
        uint minAmountOut,
        uint maxPrice
    ) external returns (uint tokenAmountOut, uint spotPriceAfter);

    function swapExactAmountOut(
        address tokenIn,
        uint maxAmountIn,
        address tokenOut,
        uint tokenAmountOut,
        uint maxPrice
    ) external returns (uint tokenAmountIn, uint spotPriceAfter);

    function calcOutGivenIn(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint tokenAmountIn,
        uint swapFee
    ) external view returns (uint tokenAmountOut);
}

