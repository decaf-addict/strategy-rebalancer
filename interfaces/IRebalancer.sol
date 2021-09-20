// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IRebalancer {
    function tokenA() external returns (IERC20);

    function tokenB() external returns (IERC20);

    function shouldHarvest() external view returns (bool);

    function shouldTend() external view returns (bool);

    function name() external view returns (string[] memory);

    function collectTradingFees() external;

    function sellRewards() external;

    function adjustPosition() external;

    function liquidatePosition(uint _amountNeeded, IERC20 _token, address _to) external;

    function liquidateAllPositions(IERC20 _token, address _to) external;

    function evenOut() external;

    function migrateProvider(address _newProvider) external;

    function balanceOfReward() external view returns (uint);

    function balanceOfLbp() external view returns (uint);

    function looseBalanceA() external view returns (uint);

    function looseBalanceB() external view returns (uint);

    function pooledBalanceA() external view returns (uint);

    function pooledBalanceB() external view returns (uint);

    function pooledBalance(uint index) external view returns (uint);

    function totalBalanceOf(IERC20 _token) external view returns (uint);

    function currentWeightA() external view returns (uint);

    function currentWeightB() external view returns (uint);

    function tokenIndex(IERC20 _token) external view returns (uint _tokenIndex);

    function ethToWant(address _want, uint _amtInWei) external view returns (uint _wantAmount);
}