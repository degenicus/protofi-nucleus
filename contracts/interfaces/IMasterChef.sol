// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IMasterChef {
    function deposit(uint256 poolId, uint256 _amount) external;

    function withdraw(uint256 poolId, uint256 _amount) external;

    function userInfo(uint256 _pid, address _user)
        external
        view
        returns (uint256, uint256);

    function pendingProton(uint256 _pid, address _user)
        external
        view
        returns (uint256);

    function emergencyWithdraw(uint256 _pid) external;
}