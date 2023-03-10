// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/Ive.sol";
import "../interfaces/IveListener.sol";
import "../utils/ContractGuard.sol";
import "../interfaces/IveShareRoom.sol";

contract Voter is IveListener, ContractGuard, ReentrancyGuard, PausableUpgradeable, OwnableUpgradeable {
    address public ve; // the ve token that governs these contracts
    uint256 public totalWeight; // total voting weight

    uint256 public poolLength; // all pools viable for voting

    uint256[] public poolWeightMin; // poolId => min weight
    uint256[] public poolWeightMax; // poolId => max weight

    mapping(uint256 => uint256) public weights; // poolId => weight
    mapping(uint256 => mapping(uint256 => uint256)) public votes; // nft => poolId => votes
    mapping(uint256 => uint256[]) public poolVote; // nft => pools
    mapping(uint256 => uint256) public usedWeights;  // nft => total voting weight of user

    address public boardroom; // VeCssRoom
    uint256 public epochReward;

    event Voted(address indexed voter, uint256 tokenId, uint256 weight);
    event Abstained(uint256 tokenId, uint256 weight);

    function initialize(address __ve) external initializer {
        PausableUpgradeable.__Pausable_init();
        OwnableUpgradeable.__Ownable_init();

        // 45% to reward veBCXS stakers on Boardroom
        // 35% to buy back BCXS and burn immediately
        // 10% to Collateral Reserve
        // 10% to DAO Fund
        ve = __ve;
        poolLength = 4; // [0, 1, 2] = [Boardroom, Burn, Reserve, DAO]

        poolWeightMin = [3000, 2000, 500, 500];
        poolWeightMax = [6000, 5000, 1500, 1500];
    }

    function setNewVe(address _newVe) external onlyOwner {
        require(_newVe != address(0), "zero");
        ve = _newVe;
    }

    function reset(uint256 _tokenId) external onlyOneBlock whenNotPaused {
        require(Ive(ve).isApprovedOrOwner(msg.sender, _tokenId) || getStakerOfNft(_tokenId) == msg.sender, "!owned");
        _reset(_tokenId);
        Ive(ve).abstain(_tokenId);
    }

    function _reset(uint256 _tokenId) internal {
        uint256[] storage _poolVote = poolVote[_tokenId];
        uint256 _poolVoteCnt = _poolVote.length;
        uint256 _totalWeight = 0;

        for (uint256 i = 0; i < _poolVoteCnt; i ++) {
            uint256 _poolId = _poolVote[i];
            uint256 _votes = votes[_tokenId][_poolId];

            if (_votes != 0) {
                weights[_poolId] -= _votes;
                votes[_tokenId][_poolId] -= _votes;
                _totalWeight += _votes;
                emit Abstained(_tokenId, _votes);
            }
        }
        totalWeight -= uint256(_totalWeight);
        usedWeights[_tokenId] = 0;
        delete poolVote[_tokenId];
    }

    function onTokenWeightUpdated(uint256 _tokenId) external override {
        if (poolVote[_tokenId].length > 0) {
            poke(_tokenId);
        }
    }

    function poke(uint256 _tokenId) public onlyOneBlock whenNotPaused {
        uint256[] memory _poolVote = poolVote[_tokenId];
        uint256 _poolCnt = _poolVote.length;
        uint256[] memory _weights = new uint256[](poolLength);

        uint256 _totalVoteWeight = 0;
        for (uint256 i = 0; i < _poolCnt; i ++) {
            _weights[i] = votes[_tokenId][_poolVote[i]];
            _totalVoteWeight += _weights[i];
        }

        _vote(_tokenId, _weights, _totalVoteWeight);
    }

    function _vote(uint256 _tokenId, uint256[] memory _weights, uint256 _totalVoteWeight) internal {
        uint256 _poolCnt = poolLength;

        _reset(_tokenId);
        uint256 _weight = uint256(Ive(ve).balanceOfNFT(_tokenId));
        uint256 _totalWeight = 0;
        uint256 _usedWeight = 0;

        for (uint256 i = 0; i < _poolCnt; i++) {
            uint256 _poolWeight = _weights[i] * _weight / _totalVoteWeight;
            require(votes[_tokenId][i] == 0);
            require(_poolWeight != 0);

            poolVote[_tokenId].push(i);

            weights[i] += _poolWeight;
            votes[_tokenId][i] += _poolWeight;

            _usedWeight += _poolWeight;
            _totalWeight += _poolWeight;
            emit Voted(msg.sender, _tokenId, _poolWeight);
        }
        if (_usedWeight > 0) Ive(ve).voting(_tokenId);
        totalWeight += uint256(_totalWeight);
        usedWeights[_tokenId] = uint256(_usedWeight);
    }

    function vote(uint256 _tokenId, uint256[] calldata _weights) external onlyOneBlock whenNotPaused {
        require(Ive(ve).isApprovedOrOwner(msg.sender, _tokenId) || getStakerOfNft(_tokenId) == msg.sender, "!owned");
        uint256 _poolCnt = poolLength;
        require(_weights.length == _poolCnt, "length mismatch");
        uint256 _totalVoteWeight = 0;
        uint256 i;
        for (i = 0; i < _poolCnt; i++) {
            uint256 _w = _weights[i];
            require(_w >= poolWeightMin[i] && _w <= poolWeightMax[i], "out of range");
            _totalVoteWeight += _w;
        }
        require(_totalVoteWeight == 10000, "total not 100 percent");
        _vote(_tokenId, _weights, _totalVoteWeight);
    }

    function addPool(uint256 _weightMin, uint256 _weightMax) external onlyOwner {
        require(_weightMin >= 0 && _weightMin <= _weightMax && _weightMax <= 10000, "out of range");
        poolLength++;
        poolWeightMin.push(_weightMin);
        poolWeightMax.push(_weightMax);
    }

    function setBoardroom(address _boardroom) external onlyOwner {
        boardroom = _boardroom;
    }

    function getStakerOfNft(uint256 _tokenId) public view returns (address) {
        address _boardroom = boardroom;
        return _boardroom == address(0) ? address(0) : IveShareRoom(_boardroom).stakerOfNFT(_tokenId);
    }

    function length() external view returns (uint256) {
        return poolLength;
    }

    /* ========== EMERGENCY ========== */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueStuckErc20(address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), IERC20(_token).balanceOf(address(this)));
    }
}
