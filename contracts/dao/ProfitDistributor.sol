// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IBasisAsset.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IveShareRoom.sol";
import "../interfaces/IProfitDistributor.sol";
import "../core/CollateralReserve.sol";

contract ProfitDistributor is OwnableUpgradeable, IProfitDistributor {
    using SafeERC20 for IERC20;

    address public share; // BCXS
    address public cake;
    address[] public cake2SharePath;
    address public boardroom;
    address public daoFund;
    address public reserve;

    address public router; // WBNB Router

    uint256 public shareBurnPercent;
    uint256 public daoFundPercent;
    uint256 public reservePercent;

    /* ========== EVENTS ========== */

    event BoardroomUpdated(address indexed newBoardroom);
    event DaoFundUpdated(address indexed newDaoFund);
    event ReserveUpdated(address indexed newReserve);
    event RouterUpdated(address indexed newRouter);
    event ShareBurnPercentUpdated(uint256 newShareBurnPercent);
    event DaoFundPercentUpdated(uint256 newDaoPercent);
    event ReservePercentUpdated(uint256 reservePercent);
    event SwapToken(address inputToken, address outputToken, uint256 amount, uint256 amountReceived);
    event BurnToken(address indexed token, uint256 amount);
    event ForwardFund(address indexed token, address fund, uint256 amount);

    /* ========== Modifiers =============== */

    function initialize(address _share, address _cake, address _boardroom, address _router) external initializer {
        OwnableUpgradeable.__Ownable_init();

        share = _share;
        cake = _cake;
        cake2SharePath = [_cake, _share];

        boardroom = _boardroom;
        router = _router;

        // 45% to reward veBCXS stakers on Boardroom
        // 35% to buy back BCXS and burn immediately
        // 10% to Collateral Reserve
        // 10% to DAO Fund
        shareBurnPercent = 3500;
        daoFundPercent = 1000;
        reservePercent = 1000;
    }

    /* ========== VIEWS ================ */

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setBoardroom(address _boardroom) public onlyOwner {
        require(_boardroom != address(0), "zero");
        boardroom = _boardroom;
        emit BoardroomUpdated(_boardroom);
    }

    function setDaoFund(address _daoFund) public onlyOwner {
        require(_daoFund != address(0), "zero");
        daoFund = _daoFund;
        emit DaoFundUpdated(_daoFund);
    }

    function setReserve(address _reserve) public onlyOwner {
        require(_reserve != address(0), "zero");
        reserve = _reserve;
        emit ReserveUpdated(_reserve);
    }

    function setRouter(address _router) public onlyOwner {
        require(_router != address(0), "zero");
        router = _router;
        emit RouterUpdated(_router);
    }

    function setDistributionPercents(uint256 _shareBurnPercent, uint256 _daoFundPercent, uint256 _reservePercent) public onlyOwner {
        require(_shareBurnPercent + _daoFundPercent + _reservePercent <= 10000, "over 100 percent");
        shareBurnPercent = _shareBurnPercent;
        daoFundPercent = _daoFundPercent;
        reservePercent = _reservePercent;
        emit ShareBurnPercentUpdated(_shareBurnPercent);
        emit DaoFundPercentUpdated(_daoFundPercent);
        emit ReservePercentUpdated(_reservePercent);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function pullRewards(uint256 _cakeAmount) external override {
        IERC20 _cake = IERC20(cake);
        address _share = share;
        address _boardroom = boardroom;
        address _daoFund = daoFund;
        address _reserve = reserve;

        _cake.safeTransferFrom(msg.sender, address(this), _cakeAmount);

        uint256 _cakeBal = _cake.balanceOf(address(this));

        _swapCakeToShare(_cakeBal * shareBurnPercent / 10000);
        uint256 _shareBal = IERC20(_share).balanceOf(address(this));
        IBasisAsset(_share).burn(_shareBal);

        uint256 _daoFundAmt = _cakeBal * daoFundPercent / 10000;
        _cake.safeTransfer(_daoFund, _daoFundAmt);

        uint256 _reserveAmt = _cakeBal * reservePercent / 10000;
        _cake.safeTransfer(_reserve, _reserveAmt);

        _cakeBal = _cake.balanceOf(address(this));
        _approveTokenIfNeeded(address(_cake), _boardroom);
        IveShareRoom(_boardroom).topupEpochReward(_cakeBal);

        emit BurnToken(_share, _shareBal);
        emit ForwardFund(address(_cake), _daoFund, _daoFundAmt);
        emit ForwardFund(address(_cake), _reserve, _reserveAmt);
        emit ForwardFund(address(_cake), _boardroom, _cakeBal);
    }

    /* ========== LIBRARIES ========== */

    function _approveTokenIfNeeded(address _token, address _spender) private {
        if (IERC20(_token).allowance(address(this), _spender) < type(uint256).max >> 1) {
            IERC20(_token).approve(_spender, type(uint256).max);
        }
    }

    function _swapCakeToShare(uint256 _amount) internal {
        if (_amount == 0) return;
        address _inputToken = cake;
        address _outputToken = share;
        address _router = router;
        _approveTokenIfNeeded(_inputToken, _router);
        uint256[] memory rAmounts = IUniswapV2Router(_router).swapExactTokensForTokens(_amount, 1, cake2SharePath, address(this), block.timestamp);
        emit SwapToken(_inputToken, _outputToken, _amount, rAmounts[rAmounts.length - 1]);
    }

    /* ========== EMERGENCY ========== */

    function rescueStuckErc20(address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
