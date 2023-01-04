// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IDollar.sol";
import "../interfaces/ITreasury.sol";

contract ShareToken is IDollar, ERC20Burnable, Ownable {
    address public treasury;
    mapping(address => bool) public minter;

    uint256 public constant T_ZERO_TIMESTAMP = 1669852800; // (Thursday, 1 December 2022 00:00:00 UTC)

    uint256 public dailyMintingCap = 1000000 ether; // 1 million daily
    uint256 public lastMintingDay;
    uint256 public todayMintedAmount;

    uint256 public totalMinted;
    uint256 public totalBurned;

    bool public liquidityMiningDistributed = false;

    /* ========== EVENTS ========== */

    event TreasuryUpdated(address indexed newTreasury);
    event MinterUpdated(address indexed account, bool isMinter);
    event DailyMintingCapUpdated(uint256 newCap);
    event AssetBurned(address indexed from, address indexed to, uint256 amount);
    event AssetMinted(address indexed from, address indexed to, uint256 amount);

    /* ========== Modifiers =============== */

    modifier onlyPool() {
        require(ITreasury(treasury).hasPool(msg.sender), "!pool");
        _;
    }

    modifier onlyMinter() {
        require(minter[msg.sender] || ITreasury(treasury).hasPool(msg.sender), "!minter");
        _;
    }

    /* ========== GOVERNANCE ========== */

    constructor(address _treasury, uint256 _genesis_supply) ERC20("BNB Cake Share", "BCXS") {
        treasury = _treasury;
        minter[msg.sender] = true;
        _mint(msg.sender, _genesis_supply);
        totalMinted = _genesis_supply; // 1 million
    }

    function setTreasuryAddress(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setMinterStatus(address _account, bool _isMinter) external onlyOwner {
        minter[_account] = _isMinter;
        emit MinterUpdated(_account, _isMinter);
    }

    function setDailyMintingCap(uint256 _dailyMintingCap) external onlyOwner {
        dailyMintingCap = _dailyMintingCap;
        emit DailyMintingCapUpdated(_dailyMintingCap);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getDayIndex() public view returns (uint256) {
        return (block.timestamp - T_ZERO_TIMESTAMP) / 24 hours;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function burn(uint256 _amount) public override {
        super.burn(_amount);
        unchecked{totalBurned += _amount;}
    }

    function poolBurnFrom(address _address, uint256 _amount) external override onlyPool {
        super._burn(_address, _amount);
        unchecked{totalBurned += _amount;}
        emit AssetBurned(_address, msg.sender, _amount);
    }

    function poolMint(address _address, uint256 _amount) external override onlyMinter {
        uint256 _todayIndex = getDayIndex();
        if (_todayIndex > lastMintingDay) {
            lastMintingDay = _todayIndex;
            todayMintedAmount = _amount;
        } else {
            todayMintedAmount += _amount;
       }
        require(todayMintedAmount <= dailyMintingCap, "exceed daily minting cap");
        super._mint(_address, _amount);
        unchecked{totalMinted += _amount;}
        emit AssetMinted(msg.sender, _address, _amount);
    }

    /* ========== EMERGENCY ========== */

    function rescueStuckErc20(address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
