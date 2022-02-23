// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IMoneyPot {

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20Upgradeable stakeToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool.
        uint256 lastRewardBlock;  // Last block number that reward distribution occurs.
        uint256 accRewardPerShare; // Accumulated reward per share, times 1e12. See below.
    }

    function rewardToken() external view returns (IERC20Upgradeable);

    function poolInfo(uint256 _poolId) external view returns (PoolInfo memory);

    function userInfo(address _userAddress)
        external
        view
        returns (uint256 amount, uint256 rewardDebt);


    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) external view returns (uint256);

    // View function to see pending Reward on frontend.
    function pendingReward(address _user) external view returns (uint256);

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) external;

    // Stake staking tokens to moneypot
    function deposit(uint256 _amount) external;

    // Withdraw stake tokens from STAKING.
    function withdraw(uint256 _amount) external;

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() external;
}