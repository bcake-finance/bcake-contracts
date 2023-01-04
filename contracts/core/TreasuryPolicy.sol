// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/ITreasuryPolicy.sol";

contract TreasuryPolicy is OwnableUpgradeable, ITreasuryPolicy {
    address public treasury;

    // fees
    uint256 public override redemption_fee; // 4 decimals of precision
    uint256 public constant REDEMPTION_FEE_MAX = 200; // 2.0%

    uint256 public override minting_fee; // 4 decimals of precision
    uint256 public constant MINTING_FEE_MAX = 100; // 1.0%

    // =0: NO FARM
    // =10000: 100% to farm (CRO+WBNB farm for WBNB on cake.finance)
    uint256 public override reserve_farming_percent;

    mapping(address => bool) public strategist;

    /* ========== EVENTS ============= */

    event StrategistStatusUpdated(address indexed account, bool status);
    event MintingFeeUpdated(uint256 fee);
    event RedemptionFeeUpdated(uint256 fee);
    event ReserveFarmingPercentUpdated(uint256 percent);

    /* ========== MODIFIERS ========== */

    modifier onlyTreasuryOrOwner {
        require(msg.sender == treasury || msg.sender == owner(), "!treasury && !owner");
        _;
    }

    modifier onlyStrategist() {
        require(strategist[msg.sender] || msg.sender == treasury || msg.sender == owner(), "!strategist && !treasury && !owner");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        address _treasury,
        uint256 _minting_fee,
        uint256 _redemption_fee
    ) external initializer {
        OwnableUpgradeable.__Ownable_init();

        treasury = _treasury;

        minting_fee = _minting_fee;
        redemption_fee = _redemption_fee;

        reserve_farming_percent = 9500; // 95%
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setStrategistStatus(address _account, bool _status) external onlyOwner {
        strategist[_account] = _status;
        emit StrategistStatusUpdated(_account, _status);
    }

    function setMintingFee(uint256 _minting_fee) external override onlyStrategist {
        require(_minting_fee <= MINTING_FEE_MAX, ">MINTING_FEE_MAX");
        minting_fee = _minting_fee;
        emit MintingFeeUpdated(_minting_fee);
    }

    function setRedemptionFee(uint256 _redemption_fee) external override onlyStrategist {
        require(_redemption_fee <= REDEMPTION_FEE_MAX, ">REDEMPTION_FEE_MAX");
        redemption_fee = _redemption_fee;
        emit RedemptionFeeUpdated(_redemption_fee);
    }

    function setReserveFarmingPercent(uint256 _reserve_farming_percent) external override onlyStrategist {
        reserve_farming_percent = _reserve_farming_percent;
        emit ReserveFarmingPercentUpdated(_reserve_farming_percent);
    }

    /* ========== EMERGENCY ========== */

    function rescueStuckErc20(address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
