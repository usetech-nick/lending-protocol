// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel public interestRateModel;

    uint256 public constant RAY = 1e27;
    uint256 public constant KINK = 8e26; // 80% utilization
    uint256 public constant SLOPE1 = 2e26; // 20% per 100% utilization up to kink
    uint256 public constant SLOPE2 = 1e27; // 100% interest after kink
    uint256 public constant BASE_RATE = 2e25; // 0.2% base rate

    function setUp() external {
        interestRateModel = new InterestRateModel(KINK, BASE_RATE, SLOPE1, SLOPE2);
    }

    function testZeroDepositReturnsBaseRate() external {
        assertEq(interestRateModel.getBorrowRate(0, 0), BASE_RATE);
    }

    function testUtilizationBelowKink() external {
        uint256 totalBorrow = 5;
        uint256 totalDeposit = 10;
        uint256 utilization = (totalBorrow * RAY) / totalDeposit;

        uint256 expectedBorrowRate = BASE_RATE + (SLOPE1 * utilization) / RAY;

        assertEq(interestRateModel.getBorrowRate(totalBorrow, totalDeposit), expectedBorrowRate);
    }

    function testUtilizationAtKink() external {
        uint256 totalBorrow = 8;
        uint256 totalDeposit = 10;
        uint256 utilization = (totalBorrow * RAY) / totalDeposit;

        uint256 expectedBorrowRate = BASE_RATE + (SLOPE1 * utilization) / RAY;

        assertEq(interestRateModel.getBorrowRate(totalBorrow, totalDeposit), expectedBorrowRate);
    }

    function testUtilizationAboveKink() external {
        uint256 totalBorrow = 9;
        uint256 totalDeposit = 10;
        uint256 utilization = (totalBorrow * RAY) / totalDeposit;
        uint256 excessUtil = utilization - KINK;

        uint256 expectedBorrowRate = BASE_RATE + SLOPE1 + (SLOPE2 * excessUtil) / (RAY - KINK);

        assertEq(interestRateModel.getBorrowRate(totalBorrow, totalDeposit), expectedBorrowRate);
    }
}
