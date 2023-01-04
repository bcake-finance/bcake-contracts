// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

interface IProfitDistributor {
    function pullRewards(uint256 _cakeAmount) external;
}
