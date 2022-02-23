// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IElectronToken is IERC20Upgradeable {

    function getPenaltyPercent(address _holderAddress) external view returns (uint256);

    function swapToProton(uint256 _amount) external;

    function previewSwapProtonExpectedAmount(address _holderAddress, uint256 _electronAmount) external view returns (uint256 expectedProton);
    
}