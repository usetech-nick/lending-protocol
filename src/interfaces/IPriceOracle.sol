// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPriceOracle {
    function getUnderlyingPrice(address token) external view returns (uint256);
    function getPrice(address token) external view returns (uint256);
}
