// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/ICakeFarmingPool.sol";
import "../interfaces/IProfitDistributor.sol";

contract StrategyPcsLpBnbCake is Ownable, ReentrancyGuard, Pausable, IStrategy {
    using SafeERC20 for IERC20;

    address public controller;
    address public operator;
    address public strategist;

    address public override want;
    address public override farmingToken;

    address public farmingPool;
    uint256 public farmingPoolId;

    address public profitDistributor;

    address public router = address(0x10ED43C718714eb63d5aA57B78B54704E256024E); // Pancakeswap Router
    mapping(address => mapping(address => address[])) public routerPaths;

    address public usdc;

    address public timelock;
    bool public notPublic = false; // allow public to call earn() function

    uint256 public lastEarnTime = 0;

    uint256 public operatorFee = 100; // 100 = 1%

    uint256 public autoEarnLimit = 1000 ether; // $1000
    uint256 public autoEarnDelaySeconds = 72 hours; // 3 days

    event Deposit(uint256 amount);
    event Withdraw(uint256 amount);
    event Farm(uint256 amount);
    event Earned(address earnedAddress, uint256 earnedAmt);
    event DistributeFee(address earnedAddress, uint256 fee, address receiver);
    event InCaseTokensGetStuck(address tokenAddress, uint256 tokenAmt, address receiver);
    event ExecuteTransaction(address indexed target, uint256 value, string signature, bytes data);

    constructor(
        address _controller,
        address _want,
        address _farmingToken,
        address _farmingPool,
        uint256 _farmingPoolId,
        address _usdc
    ) {
        controller = _controller;

        want = _want;
        farmingToken = _farmingToken;
        farmingPool = _farmingPool;
        farmingPoolId = _farmingPoolId;

        usdc = _usdc;

        routerPaths[_farmingToken][_usdc] = [_farmingToken, _usdc];

        strategist = msg.sender; // to call earn if public not allowed
        operator = msg.sender;
    }

    modifier onlyStrategist() {
        require(strategist == msg.sender || operator == msg.sender, "caller is not the strategist");
        _;
    }

    modifier onlyController() {
        require(controller == msg.sender, "caller is not the controller");
        _;
    }

    modifier onlyTimelock() {
        require(timelock == msg.sender, "caller is not timelock");
        _;
    }

    function getName() public pure returns (string memory) {
        return "Bcake.Finance:StrategyPcsLpBnbCake";
    }

    function _farm() internal {
        address _want = want;
        uint256 _wantBal = IERC20(_want).balanceOf(address(this));
        _approveTokenIfNeeded(_want, farmingPool);
        ICakeFarmingPool(farmingPool).deposit(farmingPoolId, _wantBal);
    }

    function _withdrawSome(uint _amount) internal {
        ICakeFarmingPool(farmingPool).withdraw(farmingPoolId, _amount);
    }

    function _exit() internal {
        ICakeFarmingPool(farmingPool).withdraw(farmingPoolId, inFarmBalance());
    }

    function _emergencyExit() internal {
        ICakeFarmingPool(farmingPool).emergencyWithdraw(farmingPoolId);
    }

    function inFarmBalance() public view returns (uint256 _amount) {
        (_amount, ) = ICakeFarmingPool(farmingPool).userInfo(farmingPoolId, address(this));
    }

    function _harvest() internal {
        return ICakeFarmingPool(farmingPool).withdraw(farmingPoolId, 0);
    }

    function pendingHarvest() public view returns (uint256) {
        return ICakeFarmingPool(farmingPool).pendingCake(farmingPoolId, address(this));
    }

    function isAuthorised(address _account) public view returns (bool) {
        return (_account == operator) || (_account == controller) || (_account == strategist) || (_account == timelock);
    }

    function _checkAutoEarn() internal {
        if (!paused() && !notPublic) {
            uint256 _pendingHarvestDollarValue = pendingHarvestDollarValue();
            if (_pendingHarvestDollarValue >= autoEarnLimit || (_pendingHarvestDollarValue > 0) && (block.timestamp - lastEarnTime >= autoEarnDelaySeconds)) {
                earn();
            }
        }
    }

    function deposit(uint256 _wantAmt) public override onlyController whenNotPaused {
        require(_wantAmt > 0, "deposit: not good");
        _checkAutoEarn();
        IERC20(want).safeTransferFrom(address(msg.sender), address(this), _wantAmt);
        _farm();
        emit Deposit(_wantAmt);
    }

    function farm() public nonReentrant {
        _farm();
    }

    function withdraw(uint256 _wantAmt) public override onlyController whenNotPaused nonReentrant {
        require(_wantAmt > 0, "withdraw: not good");
        _checkAutoEarn();
        _withdrawSome(_wantAmt);
        IERC20(want).safeTransfer(address(msg.sender), _wantAmt);
        emit Withdraw(_wantAmt);
    }

    function totalBalance() external override view returns (uint256) {
        return IERC20(want).balanceOf(address(this)) + inFarmBalance();
    }

    function withdrawAll() external override onlyController {
        _checkAutoEarn();
        _exit();
        uint256 _wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).safeTransfer(address(msg.sender), _wantBal);
        emit Withdraw(_wantBal);
    }

    function emergencyWithdraw() external override onlyController {
        _emergencyExit();
        uint256 _wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).safeTransfer(address(msg.sender), _wantBal);
        emit Withdraw(_wantBal);
    }

    function earn() public whenNotPaused {
        require(!notPublic || isAuthorised(msg.sender), "!authorised");

        _harvest();

        // Converts farm tokens into want tokens
        address _farmingToken = farmingToken;
        uint256 _earnedAmt = IERC20(_farmingToken).balanceOf(address(this));
        if (_earnedAmt > 0) {
            uint256 _distributeFee = _distributeFees(_earnedAmt);
            _earnedAmt -= _distributeFee;

            address _profitDistributor = profitDistributor;
            if (_profitDistributor != address(0)) {
                _approveTokenIfNeeded(_farmingToken, _profitDistributor);
                IProfitDistributor(_profitDistributor).pullRewards(_earnedAmt);
            } else {
                IERC20(_farmingToken).safeTransfer(operator, _earnedAmt); // temporarily send to operator
            }

            emit Earned(_farmingToken, _earnedAmt);
        }

        lastEarnTime = block.timestamp;
    }

    function _distributeFees(uint256 _earnedAmt) internal returns (uint256 _fee) {
        if (_earnedAmt > 0) {
            // Performance fee
            if (operatorFee > 0) {
                _fee = _earnedAmt * operatorFee / 10000;
                address _farmingToken = farmingToken;
                address _operator = operator;
                IERC20(_farmingToken).safeTransfer(_operator, _fee);
                emit DistributeFee(_farmingToken, _fee, _operator);
            }
        }
    }

    function exchangeRate(address _inputToken, address _outputToken, uint256 _tokenAmount) public view returns (uint256) {
        try IUniswapV2Router(router).getAmountsOut(_tokenAmount, routerPaths[_inputToken][_outputToken]) returns (uint256[] memory amounts) {
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    function pendingHarvestDollarValue() public view returns (uint256) {
        address _farmingToken = farmingToken;
        uint256 _pending = pendingHarvest();
        uint256 _earnedAmt = IERC20(_farmingToken).balanceOf(address(this));
        return (_pending == 0 && _earnedAmt == 0) ? 0 : exchangeRate(_farmingToken, usdc, _pending + _earnedAmt);
    }

    /* ========== GOVERNANCE ========== */

    function setStrategist(address _strategist) external onlyOwner {
        require(_strategist != address(0), "invalidAddress");
        strategist = _strategist;
    }

    function setOperator(address _operator) external onlyOwner {
        require(operator != address(0), "invalidAddress");
        operator = _operator;
    }

    function setOperatorFee(uint256 _operatorFee) external onlyOwner {
        require(_operatorFee <= 1000, "too high"); // <= 10%
        operatorFee = _operatorFee;
    }

    function setProfitDistributor(address _profitDistributor) external onlyOwner {
        profitDistributor = _profitDistributor;
    }

    function setNotPublic(bool _notPublic) external onlyOwner {
        notPublic = _notPublic;
    }

    function setAutoEarnLimit(uint256 _autoEarnLimit) external onlyOwner {
        autoEarnLimit = _autoEarnLimit;
    }

    function setAutoEarnDelaySeconds(uint256 _autoEarnDelaySeconds) external onlyOwner {
        autoEarnDelaySeconds = _autoEarnDelaySeconds;
    }

    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    function setPath(address _inputToken, address _outputToken, address[] memory _path) external onlyOwner {
        routerPaths[_inputToken][_outputToken] = _path;
    }

    function _approveTokenIfNeeded(address _token, address _router) private {
        if (IERC20(_token).allowance(address(this), address(_router)) < type(uint256).max >> 1) {
            IERC20(_token).approve(address(_router), type(uint256).max);
        }
    }

    /* ========== EMERGENCY ========== */

    function pause() external onlyOwner whenNotPaused {
        super._pause();
    }

    function unpause() external onlyOwner whenPaused {
        super._unpause();
    }

    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != want, "want");
        require(_token != farmingToken, "farmingToken");
        uint256 _amount = IERC20(_token).balanceOf(address(this));
        if (_amount > 0) {
            IERC20(_token).safeTransfer(owner(), _amount);
            emit InCaseTokensGetStuck(_token, _amount, owner());
        }
    }

    function setController(address _controller) external {
        require(_controller != address(0), "invalidAddress");
        require(controller == msg.sender || timelock == msg.sender, "caller is not the controller nor timelock");
        controller = _controller;
    }

    function setTimelock(address _timelock) external onlyTimelock {
        timelock = _timelock;
    }

    /**
     * @dev This is from Timelock contract.
     */
    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data
    ) external onlyTimelock returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value : value}(callData);
        require(success, "StrategyPcsLpBnbCake::executeTransaction: Transaction execution reverted.");

        emit ExecuteTransaction(target, value, signature, data);

        return returnData;
    }
}
