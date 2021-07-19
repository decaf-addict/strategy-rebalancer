// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

interface IDSProxy {
    function execute(bytes calldata _code, bytes calldata _data) external payable returns (address target, bytes32 response);

    function execute(address _target, bytes calldata _data) external payable returns (bytes32 response);
}