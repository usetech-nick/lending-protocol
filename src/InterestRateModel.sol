// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

contract InterestRateModel is IInterestRateModel {
    uint256 public immutable kink;
    uint256 public immutable slope1;
    uint256 public immutable slope2;
    uint256 public immutable baseRate;

    uint256 public constant RAY = 1e27;

    constructor(uint256 _kink, uint256 _baseRate, uint256 _slope1, uint256 _slope2) {
        kink = _kink;
        baseRate = _baseRate;
        slope1 = _slope1;
        slope2 = _slope2;
    }

    function getBorrowRate(uint256 totalBorrow, uint256 totalDeposit) external view override returns (uint256) {
        if (totalDeposit == 0) return baseRate;

        uint256 utilization = (totalBorrow * RAY) / totalDeposit;

        if (utilization <= kink) {
            return baseRate + (slope1 * utilization) / RAY;
        } else {
            uint256 excessUtil = utilization - kink;
            return baseRate + slope1 + (slope2 * excessUtil) / (RAY - kink);
        }
    }
}
