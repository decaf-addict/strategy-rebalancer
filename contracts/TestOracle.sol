// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

contract TestOracle {
    uint256 private price;

    function decimals() public view returns (uint8){
        return 8;
    }

    function latestAnswer() public view returns (uint256){
        return price;
    }

    function setPrice(uint256 _price) public {
        price = _price;
    }
}