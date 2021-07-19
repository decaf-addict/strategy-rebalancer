// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;


interface IWETH9 {
    function balanceOf(address) external returns (uint256);

    function deposit() external payable;

    function withdraw(uint wad) external;

    function approve(address guy, uint wad) external returns (bool);

}
