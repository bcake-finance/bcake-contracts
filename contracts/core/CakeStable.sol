// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IDollar.sol";
import "../interfaces/ITreasury.sol";

contract CakeStable is IDollar, ERC20Burnable, Ownable, ReentrancyGuard {
    address public treasury;
    uint256 public totalBurned;

    /* ========== EVENTS ========== */

    event TreasuryUpdated(address indexed newTreasury);
    event AssetBurned(address indexed from, address indexed to, uint256 amount);
    event AssetMinted(address indexed from, address indexed to, uint256 amount);

    /* ========== Modifiers =============== */

    modifier onlyPool() {
        require(ITreasury(treasury).hasPool(msg.sender), "!pool");
        _;
    }

    /* ========== GOVERNANCE ========== */

    constructor(address _treasury, uint256 _genesis_supply) ERC20("BNB Cake", "BCAKE") {
        treasury = _treasury;
        if (_genesis_supply > 0) {
            _mint(msg.sender, _genesis_supply); // will be minted at genesis for liq pool seeding
        }
    }

    function setTreasuryAddress(address _treasury) public onlyOwner {
        require(_treasury != address(0), "zero");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function poolBurnFrom(address _address, uint256 _amount) external override onlyPool {
        super._burn(_address, _amount);
        unchecked{ totalBurned += _amount; }
        emit AssetBurned(_address, msg.sender, _amount);
    }

    function poolMint(address _address, uint256 _amount) external override onlyPool {
        super._mint(_address, _amount);
        emit AssetMinted(msg.sender, _address, _amount);
    }

    /* ========== EMERGENCY ========== */

    function rescueStuckErc20(address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
