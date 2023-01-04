// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IBasisAsset.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IPool.sol";
import "../interfaces/ITreasuryPolicy.sol";
import "../interfaces/ICollateralReserve.sol";

contract Treasury is ITreasury, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // addresses
    address private collateralReserve_;

    address public dollar; // BCAKE
    address public share; // BCXS

    address public mainCollateral; // CAKE
    address public secondCollateral; // WBNB

    address public treasuryPolicy;

    address public oracleDollar;
    address public oracleShare;
    address public oracleMainCollateral;
    address public oracleSecondCollateral;

    // pools
    address[] public pools_array;
    mapping(address => bool) public pools;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e18;

    mapping(address => bool) public strategist;

    /* ========== EVENTS ========== */

    event PoolAdded(address indexed pool);
    event PoolRemoved(address indexed pool);
    event ProfitExtracted(uint256 amount);
    event StrategistStatusUpdated(address indexed account, bool status);

    /* ========== MODIFIERS ========== */

    modifier onlyPool {
        require(pools[msg.sender], "!pool");
        _;
    }

    modifier onlyStrategist() {
        require(strategist[msg.sender] || msg.sender == owner(), "!strategist && !owner");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        address _dollar,
        address _share,
        address _mainCollateral,
        address _secondCollateral,
        address _treasuryPolicy,
        address _collateralReserve
    ) external initializer {
        require(_dollar != address(0), "zero");
        require(_share != address(0), "zero");
        require(_mainCollateral != address(0), "zero");
        require(_secondCollateral != address(0), "zero");

        OwnableUpgradeable.__Ownable_init();

        dollar = _dollar; // BCAKE
        share = _share; // BCXS
        mainCollateral = _mainCollateral; // CRO
        secondCollateral = _secondCollateral; // WBNB

        setTreasuryPolicy(_treasuryPolicy);
        setCollateralReserve(_collateralReserve);
    }

    /* ========== VIEWS ========== */

    function dollarPrice() public view returns (uint256) {
        return IOracle(oracleDollar).consult();
    }

    function sharePrice() public view returns (uint256) {
        return IOracle(oracleShare).consult();
    }

    function mainCollateralPrice() public view returns (uint256) {
        address _oracle = oracleMainCollateral;
        return (_oracle == address(0)) ? PRICE_PRECISION : IOracle(_oracle).consult();
    }

    function secondCollateralPrice() public view returns (uint256) {
        address _oracle = oracleSecondCollateral;
        return (_oracle == address(0)) ? PRICE_PRECISION : IOracle(_oracle).consult();
    }

    function hasPool(address _address) external view override returns (bool) {
        return pools[_address] == true;
    }

    function minting_fee() public override view returns (uint256) {
        return ITreasuryPolicy(treasuryPolicy).minting_fee();
    }

    function redemption_fee() public override view returns (uint256) {
        return ITreasuryPolicy(treasuryPolicy).redemption_fee();
    }

    function reserve_farming_percent() public override view returns (uint256) {
        return ITreasuryPolicy(treasuryPolicy).reserve_farming_percent();
    }

    function collateralReserve() public override view returns (address) {
        return collateralReserve_;
    }

    function info()
        external
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (
            dollarPrice(),
            IERC20(dollar).totalSupply(),
            globalCollateralTotalValue(),
            minting_fee(),
            redemption_fee(),
            reserve_farming_percent()
        );
    }

    function globalMainCollateralBalance() public view override returns (uint256) {
        return ICollateralReserve(collateralReserve_).fundBalance(mainCollateral) - totalUnclaimedMainCollateral();
    }

    function globalMainCollateralValue() public view override returns (uint256) {
        return globalMainCollateralBalance() * mainCollateralPrice() / PRICE_PRECISION;
    }

    function globalSecondCollateralBalance() public view override returns (uint256) {
        return ICollateralReserve(collateralReserve_).fundBalance(secondCollateral) - totalUnclaimedSecondCollateral();
    }

    function globalSecondCollateralValue() public view override returns (uint256) {
        return globalSecondCollateralBalance() * secondCollateralPrice() / PRICE_PRECISION;
    }

    function globalCollateralTotalValue() public view override returns (uint256) {
        return globalMainCollateralValue() + globalSecondCollateralValue();
    }

    // Iterate through all pools and calculate all unclaimed collaterals in all pools globally
    function totalUnclaimedMainCollateral() public view returns (uint256 _totalUnclaimed) {
        uint256 _length = pools_array.length;
        for (uint256 i = 0; i < _length; i++) {
            address _pool = pools_array[i];
            if (_pool != address(0)) {
                _totalUnclaimed += IPool(_pool).unclaimed_pool_main_collateral();
            }
        }
    }

    function totalUnclaimedSecondCollateral() public view returns (uint256 _totalUnclaimed) {
        uint256 _length = pools_array.length;
        for (uint256 i = 0; i < _length; i++) {
            address _pool = pools_array[i];
            if (_pool != address(0)) {
                _totalUnclaimed += IPool(_pool).unclaimed_pool_second_collateral();
            }
        }
    }

    function totalUnclaimedShare() public view returns (uint256 _totalUnclaimed) {
        uint256 _length = pools_array.length;
        for (uint256 i = 0; i < _length; i++) {
            address _pool = pools_array[i];
            if (_pool != address(0)) {
                _totalUnclaimed += IPool(_pool).unclaimed_pool_share();
            }
        }
    }

    function getEffectiveCollateralRatio() external view override returns (uint256) {
        uint256 _total_collateral_value = globalCollateralTotalValue();
        uint256 _total_dollar_value = IERC20(dollar).totalSupply() * dollarPrice() / PRICE_PRECISION;
        return _total_collateral_value * 10000 / _total_dollar_value;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setStrategistStatus(address _account, bool _status) external onlyOwner {
        strategist[_account] = _status;
        emit StrategistStatusUpdated(_account, _status);
    }

    function requestTransfer(address _token, address _receiver, uint256 _amount) external override onlyPool {
        ICollateralReserve(collateralReserve_).transferTo(_token, _receiver, _amount);
    }

    function reserveReceiveCollaterals(uint256 _mainCollateralAmount, uint256 _secondCollateralAmount) external override onlyPool {
        ICollateralReserve(collateralReserve_).receiveCollaterals(_mainCollateralAmount, _secondCollateralAmount);
    }

    // Add new Pool
    function addPool(address pool_address) public onlyOwner {
        require(pools[pool_address] == false, "poolExisted");
        pools[pool_address] = true;
        pools_array.push(pool_address);
        emit PoolAdded(pool_address);
    }

    // Remove a pool
    function removePool(address pool_address) public onlyOwner {
        require(pools[pool_address] == true, "!pool");
        // Delete from the mapping
        delete pools[pool_address];
        // 'Delete' from the array by setting the address to 0x0
        for (uint256 i = 0; i < pools_array.length; i++) {
            if (pools_array[i] == pool_address) {
                pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }
        emit PoolRemoved(pool_address);
    }

    function setTreasuryPolicy(address _treasuryPolicy) public onlyOwner {
        require(_treasuryPolicy != address(0), "zero");
        treasuryPolicy = _treasuryPolicy;
    }

    function setOracleDollar(address _oracleDollar) external onlyOwner {
        require(_oracleDollar != address(0), "zero");
        oracleDollar = _oracleDollar;
    }

    function setOracleShare(address _oracleShare) external onlyOwner {
        require(_oracleShare != address(0), "zero");
        oracleShare = _oracleShare;
    }

    function setOracleMainCollateral(address _oracle) external onlyOwner {
        require(_oracle != address(0), "zero");
        oracleMainCollateral = _oracle;
    }

    function setOracleSecondCollateral(address _oracle) external onlyOwner {
        require(_oracle != address(0), "zero");
        oracleSecondCollateral = _oracle;
    }

    function setCollateralReserve(address _collateralReserve) public onlyOwner {
        require(_collateralReserve != address(0), "zero");
        collateralReserve_ = _collateralReserve;
    }

    function updateProtocol() external onlyStrategist {
        if (dollarPrice() >= PRICE_PRECISION) {
            ITreasuryPolicy(treasuryPolicy).setMintingFee(20);
            ITreasuryPolicy(treasuryPolicy).setRedemptionFee(80);
        } else {
            ITreasuryPolicy(treasuryPolicy).setMintingFee(40);
            ITreasuryPolicy(treasuryPolicy).setRedemptionFee(40);
        }

        for (uint256 i = 0; i < pools_array.length; i++) {
            address _pool = pools_array[i];
            if (_pool != address(0)) {
                IPool(_pool).updateTargetCollateralRatio();
            }
        }

        address _oracle = oracleDollar;
        if (_oracle != address(0)) IOracle(_oracle).update();

        _oracle = oracleShare;
        if (_oracle != address(0)) IOracle(_oracle).update();

        _oracle = oracleMainCollateral;
        if (_oracle != address(0)) IOracle(_oracle).update();

        _oracle = oracleSecondCollateral;
        if (_oracle != address(0)) IOracle(_oracle).update();
    }

    /* ========== EMERGENCY ========== */

    function rescueStuckErc20(address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
