// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IJointProvider {

    // only called by rebalancer
    function migrateRebalancer(address payable _newRebalancer) external;

    // Helpers //
    function balanceOfWant() external view returns (uint256 _balance);

    function totalDebt() external view returns (uint256 _debt);

    function getPriceFeed() external view returns (uint256 _lastestAnswer);

    function getPriceFeedDecimals() external view returns (uint256 _dec);

    function getGovernance() external view returns (address);

    function strategist() external view returns (address);

    function want() external view returns (IERC20);

}