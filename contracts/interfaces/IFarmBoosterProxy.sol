// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

interface IFarmBoosterProxy {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function emergencyWithdraw(uint256 _pid) external;
}
