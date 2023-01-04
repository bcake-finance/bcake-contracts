// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

interface ITreasuryPolicy {
    function minting_fee() external view returns (uint256);

    function redemption_fee() external view returns (uint256);

    function reserve_farming_percent() external view returns (uint256);

    function setMintingFee(uint256 _minting_fee) external;

    function setRedemptionFee(uint256 _redemption_fee) external;

    function setReserveFarmingPercent(uint256 _reserve_farming_percent) external;
}
