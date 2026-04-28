// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILiquidationEngine {
    // This interface defines the functions that the LiquidationEngine must implement
    // It will be called by the LendingPool when a position is flagged for liquidation

    function liquidate(
        address borrower,
        address collateralToken,
        uint256 collateralAmount,
        address debtToken,
        uint256 debtAmount
    ) external view returns (uint256 collateralLiquidated, uint256 debtRepaid);
}
