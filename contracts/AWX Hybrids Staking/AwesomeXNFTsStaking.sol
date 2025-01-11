// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAwesomeXHybridNFTs.sol";
import "./lib/constants.sol";

/// @title AwesomeX Hybrid NFTs Staking Contract
contract AwesomeXNFTsStaking is Ownable2Step {
    using SafeERC20 for IERC20;

    // -------------------------- STATE VARIABLES -------------------------- //

    struct UserStake {
        uint256 rewardDebt;
        address account;
        uint8 multiplier;
    }

    IAwesomeXHybridNFTs constant AWX_NFTs = IAwesomeXHybridNFTs(AWESOMEX_NFTS);

    uint32 public currentCycle = 1;
    uint256 public totalStakedMultipliers;

    /// @notice Timestamp of the last cycle update in seconds.
    uint256 public lastCycleTs;
    /// @notice The total amount of rewards paid out to holders.
    uint256 public totalRewadsPaid;
    /// @notice The total amount of rewards accumulated.
    uint256 public totalRewardPool;
    /// @notice The minimum pool size required to trigger a new cycle.
    uint256 public minCyclePool = 100_000_000 ether;

    /// @notice Basis point incentive fee paid out for updating the cycle.
    uint16 public incentiveFeeBPS = 30;

    mapping(uint256 tokenId => UserStake) public stakeInfo;
    /// @notice Share per multiplier in a specific cycle.
    mapping(uint256 cycleId => uint256) public sharePerMultiplier;
    /// @notice A mapping of user addresses to the total amount of MZI tokens claimed by each user.
    mapping(address user => uint256) public totalClaimed;

    // ------------------------------- EVENTS ------------------------------ //

    event CycleUpdated();
    event Stake(address indexed account);
    event Claim(address indexed account);
    event Unstake(address indexed account);

    // ------------------------------- ERRORS ------------------------------ //

    error InsufficientBalance();
    error NoStakesAvailable();
    error Cooldown();
    error NoRewardsAvailable();
    error Prohibited();
    error Unauthorized();

    // ------------------------------ MODIFIERS ---------------------------- //

    modifier cycleUpdate {
        _updateCycleIfNecessary();
        _;
    }

    // ----------------------------- CONSTRUCTOR --------------------------- //

    constructor(address _owner) Ownable(_owner) {
        lastCycleTs = block.timestamp;
    }

    // --------------------------- PUBLIC FUNCTIONS ------------------------ //

    /// @notice Manually updates cycle and distributes the accumulated rewards.
    function updateCycle() external {
        if (getNextCycleTime() > block.timestamp) revert Cooldown();
        if (getRewardPool() < minCyclePool) revert InsufficientBalance();
        if (totalStakedMultipliers == 0) revert NoStakesAvailable();
        _updateCycleIfNecessary();
    }

    /// @notice Stake your AwesomeX Hybrid NFT.
    /// @param tokenId Token ID of the NFT to stake.
    function stake(uint256 tokenId) public cycleUpdate {
        if (AWX_NFTs.ownerOf(tokenId) != msg.sender) revert Unauthorized();
        AWX_NFTs.transferFrom(msg.sender, address(this), tokenId);
        uint8 tier = AWX_NFTs.tiers(tokenId);
        uint8 multiplier = _getTierMultiplier(tier);
        totalStakedMultipliers += multiplier;
        stakeInfo[tokenId] = UserStake(sharePerMultiplier[currentCycle - 1], msg.sender, multiplier);
        emit Stake(msg.sender);
    }

    /// @notice Stake multiple AwesomeX Hybrid NFTs.
    /// @param tokenIds Array of Token IDs to stake.
    function batchStake(uint256[] calldata tokenIds) external cycleUpdate {
        for (uint i = 0; i < tokenIds.length; i++) {
            stake(tokenIds[i]);
        }
    }

    /// @notice Claim rewards for staking your AwesomeX Hybrid NFT.
    /// @param tokenId Token ID of the NFT to claim rewards for.
    function claim(uint256 tokenId) external cycleUpdate {
        UserStake storage userStake = stakeInfo[tokenId];
        if (userStake.account != msg.sender) revert Unauthorized();
        uint256 claimableReward = _processClaim(userStake);
        _processRewardPayout(claimableReward);
    }

    /// @notice Claim rewards for staking multiple AwesomeX Hybrid NFT.
    /// @param tokenIds Array of Token IDs to claim rewards for.
    function batchClaim(uint256[] calldata tokenIds) external cycleUpdate {
        uint256 totalReward;
        uint256 numStakes = tokenIds.length;
        for (uint i = 0; i < numStakes; i++) {
            totalReward += _processClaim(stakeInfo[tokenIds[i]]);
        }
        _processRewardPayout(totalReward);
    }

    /// @notice Unstake your AwesomeX Hybrid NFT.
    /// @param tokenId Token ID of the NFT to unstake.
    /// @dev Claims rewards if necessary.
    function unstake(uint256 tokenId) external cycleUpdate {
        uint256 claimableReward = _processUnstake(tokenId);
        if (claimableReward > 0) _processRewardPayout(claimableReward);
        emit Unstake(msg.sender);
    }

    /// @notice Unstake multiple AwesomeX Hybrid NFT.
    /// @param tokenIds Array of Token IDs to unstake.
    /// @dev Claims rewards if necessary.
    function batchUnstake(uint256[] calldata tokenIds) external cycleUpdate {
        uint256 totalReward;
        uint256 numStakes = tokenIds.length;
        for (uint i = 0; i < numStakes; i++) {
            totalReward += _processUnstake(tokenIds[i]);
        }
        if (totalReward > 0) _processRewardPayout(totalReward);
        emit Unstake(msg.sender);
    }

    // ----------------------- ADMINISTRATIVE FUNCTIONS -------------------- //

    /// @notice Sets a new distribution incentive fee basis points.
    /// @param bps Incentive fee in basis points (1% = 100 bps).
    function setIncentiveFee(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 1000) revert Prohibited();
        incentiveFeeBPS = bps;
    }

    /// @notice Sets the minimum pool size required to trigger a new cycle.
    /// @param limit The new minimum pool size in WEI.
    function setMinCyclePool(uint256 limit) external onlyOwner {
        minCyclePool = limit;
    }

    // ---------------------------- VIEW FUNCTIONS ------------------------- //

    /// @notice The date when new cycle will be available.
    function getNextCycleTime() public view returns (uint256) {
        return lastCycleTs + CYCLE_LENGTH;
    }

    /// @notice Get current status of cycle update.
    /// @return isUpdateNeeded Is manual update available / will auto-update be performed.
    /// @return newShare Share to be allocated in the next cycle update.
    function getCycleStatus() external view returns (bool isUpdateNeeded, uint256 newShare) {
        bool timeReq = getNextCycleTime() <= block.timestamp;
        bool balanceReq = getRewardPool() >= minCyclePool;
        bool multiplierReq = totalStakedMultipliers > 0;
        isUpdateNeeded = timeReq && balanceReq && multiplierReq;
        if (isUpdateNeeded) {
            uint256 rewardPool = getRewardPool();
            rewardPool -= rewardPool * incentiveFeeBPS / BPS_BASE;
            newShare = (rewardPool * 1e18) / totalStakedMultipliers;
        }
    }

    /// @notice Total TitanX available for next cycle creation.
    function getRewardPool() public view returns (uint256) {
        return IERC20(TITANX).balanceOf(address(this)) + totalRewadsPaid - totalRewardPool;
    }

    /// @notice Claimable rewards available for NFT.
    /// @param tokenId Token ID of the NFT to check rewards for.
    function getClaimableRewards(uint256 tokenId) external view returns (uint256) {
        (uint256 claimableReward, ) = _getClaimableRewards(stakeInfo[tokenId]);
        return claimableReward;
    }

    /// @notice Claimable rewards available for a batch of NFTs.
    /// @param tokenIds Array of Token IDs to check rewards for.
    /// @return totalReward Total claimable rewards.
    /// @return availability Does respective NFT have claimable rewards.
    function batchGetClaimableRewards(uint256[] calldata tokenIds) external view returns (uint256 totalReward, bool[] memory availability) {
        availability = new bool[](tokenIds.length);
        for (uint i = 0; i < tokenIds.length; i++) {
            (uint256 claimableReward, ) = _getClaimableRewards(stakeInfo[tokenIds[i]]);
            totalReward += claimableReward;
            availability[i] = claimableReward > 0;
        }
    }

    // -------------------------- INTERNAL FUNCTIONS ----------------------- //

  function _updateCycleIfNecessary() internal {
        if (getNextCycleTime() > block.timestamp) return;
        uint256 _totalStakedMultipliers = totalStakedMultipliers;
        if (_totalStakedMultipliers == 0) return;
        uint256 rewardPool = getRewardPool();
        if (rewardPool < minCyclePool) return;

        lastCycleTs = block.timestamp;
        uint32 _currentCycle = currentCycle++;

        rewardPool = _processIncentiveFee(rewardPool);
        uint256 share = (rewardPool * 1e18) / _totalStakedMultipliers;
        sharePerMultiplier[_currentCycle] = sharePerMultiplier[_currentCycle - 1] + share;
        totalRewardPool += rewardPool;

        emit CycleUpdated();
    }
    
    function _getClaimableRewards(UserStake memory userStake) internal view returns (uint256 claimableReward, uint256 newRewardDebt) {
        newRewardDebt = sharePerMultiplier[currentCycle - 1];
        uint256 claimableShare = newRewardDebt - userStake.rewardDebt;
        claimableReward = (claimableShare * userStake.multiplier) / 1e18;
    }

    function _processClaim(UserStake storage userStake) internal returns (uint256) {
        if (userStake.account != msg.sender) revert Unauthorized();
        (uint256 claimableReward, uint256 newRewardDebt) = _getClaimableRewards(userStake);
        if (claimableReward == 0) revert NoRewardsAvailable();
        userStake.rewardDebt = newRewardDebt;
        return claimableReward;
    }

    function _processUnstake(uint256 tokenId) internal returns (uint256 claimableReward) {
        UserStake memory userStake = stakeInfo[tokenId];
        if (userStake.account != msg.sender) revert Unauthorized();
        (claimableReward, ) = _getClaimableRewards(userStake);
        totalStakedMultipliers -= userStake.multiplier;
        delete stakeInfo[tokenId];
        AWX_NFTs.transferFrom(address(this), msg.sender, tokenId);
    }

    function _processRewardPayout(uint256 amount) internal {
        totalClaimed[msg.sender] += amount;
        totalRewadsPaid += amount;
        IERC20(TITANX).safeTransfer(msg.sender, amount);
        emit Claim(msg.sender);
    }

    function _processIncentiveFee(uint256 amount) internal returns (uint256) {
        uint256 incentive = amount * incentiveFeeBPS / BPS_BASE;
        IERC20(TITANX).safeTransfer(msg.sender, incentive);
        return amount - incentive;
    }

    function _getTierMultiplier(uint8 tier) internal pure returns (uint8) {
        uint8 modulo = tier % 3;
        if (modulo == 0) return ELITE_MULTIPLIER;
        if (modulo == 2) return GOLD_MULTIPLIER;
        return AWESOME_MULTIPLIER;
    }
}