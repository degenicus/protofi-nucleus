// SPDX-License-Identifier: agpl-3.0

pragma solidity 0.8.11;

interface IZap {
    function estimateZapInToken(
        address _from,
        address _to,
        address _router,
        uint256 _amt
    ) external view returns (uint256, uint256);

    function swapToken(
        address _from,
        uint256 amount,
        address _to,
        address routerAddr,
        address _recipient
    ) external;

    function swapToNative(
        address _from,
        uint256 amount,
        address routerAddr,
        address _recipient
    ) external;

    function zapIn(
        address _to,
        address routerAddr,
        address _recipient
    ) external payable;

    function zapInToken(
        address _from,
        uint256 amount,
        address _to,
        address routerAddr,
        address _recipient
    ) external;

    function zapAcross(
        address _from,
        uint256 amount,
        address _toRouter,
        address _recipient
    ) external;

    function zapOut(
        address _from,
        uint256 amount,
        address routerAddr,
        address _recipient
    ) external;

    function zapOutToken(
        address _from,
        uint256 amount,
        address _to,
        address routerAddr,
        address _recipient
    ) external;
}
