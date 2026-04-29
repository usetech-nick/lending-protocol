// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {ILiquidationEngine} from "./interfaces/ILiquidationEngine.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

struct ReserveData {
    uint256 totalDeposits; // total principal deposited
    uint256 totalBorrows; // total principal borrowed
    uint256 borrowIndex; // grows at borrowRate — tracks debt accrual
    uint256 depositIndex; // grows at supplyRate — tracks deposit yield
    uint256 lastUpdatedTimestamp;
    uint256 ltv; // max borrow % e.g. 0.8e27 = 80%
    uint256 liquidationThreshold; // HF drops below 1 when debt > collateral * this
    uint256 liquidationBonus; // extra % liquidator receives e.g. 0.05e27 = 5%
    bool isActive;
}

contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── state ──────────────────────────────────────────────────────────────

    mapping(address => ReserveData) public reserves;

    mapping(address => mapping(address => uint256)) public userDeposits; // user → token → scaled deposit
    mapping(address => mapping(address => uint256)) public userBorrows; // user → token → scaled borrow

    // ── constants & immutables ─────────────────────────────────────────────

    uint256 public constant RAY = 1e27;

    address public immutable WETH;
    address public immutable USDC;

    IInterestRateModel public immutable interestRateModel;
    IPriceOracle public immutable priceOracle;
    ILiquidationEngine public immutable liquidationEngine;

    // ── events ─────────────────────────────────────────────────────────────

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event ReserveInitialized(address indexed token);

    // ── errors ─────────────────────────────────────────────────────────────

    error LendingPool__ReserveNotActive();
    error LendingPool__InsufficientCollateral();
    error LendingPool__InsufficientLiquidity();
    error LendingPool__InvalidAmount();
    error LendingPool__InvalidToken();

    // ── constructor ────────────────────────────────────────────────────────

    constructor(
        address _interestRateModel,
        address _priceOracle,
        address _liquidationEngine,
        address _weth,
        address _usdc
    ) Ownable(msg.sender) {
        interestRateModel = IInterestRateModel(_interestRateModel);
        priceOracle = IPriceOracle(_priceOracle);
        liquidationEngine = ILiquidationEngine(_liquidationEngine);
        WETH = _weth;
        USDC = _usdc;
    }

    // ── reserve initialization ─────────────────────────────────────────────

    function initReserve(address token, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus)
        external
        onlyOwner
    {
        ReserveData storage reserve = reserves[token];
        reserve.borrowIndex = RAY; // start at 1.0
        reserve.depositIndex = RAY; // start at 1.0
        reserve.lastUpdatedTimestamp = block.timestamp;
        reserve.ltv = ltv;
        reserve.liquidationThreshold = liquidationThreshold;
        reserve.liquidationBonus = liquidationBonus;
        reserve.isActive = true;
        emit ReserveInitialized(token);
    }

    // ── internal: index update ─────────────────────────────────────────────

    function _updateReserveIndex(address token) internal {
        ReserveData storage reserve = reserves[token];

        uint256 timeElapsed = block.timestamp - reserve.lastUpdatedTimestamp;
        if (timeElapsed == 0) return;

        if (reserve.totalDeposits > 0) {
            uint256 borrowRate = interestRateModel.getBorrowRate(reserve.totalBorrows, reserve.totalDeposits);

            uint256 utilization = (reserve.totalBorrows * RAY) / reserve.totalDeposits;
            uint256 supplyRate = (borrowRate * utilization) / RAY;

            reserve.borrowIndex = reserve.borrowIndex * (RAY + borrowRate * timeElapsed) / RAY;
            reserve.depositIndex = reserve.depositIndex * (RAY + supplyRate * timeElapsed) / RAY;
        }

        reserve.lastUpdatedTimestamp = block.timestamp;
    }

    // ── internal: actual balance helpers ──────────────────────────────────

    function _actualDeposit(address user, address token) internal view returns (uint256) {
        return userDeposits[user][token] * reserves[token].depositIndex / RAY;
    }

    function _actualDebt(address user, address token) internal view returns (uint256) {
        return userBorrows[user][token] * reserves[token].borrowIndex / RAY;
    }

    // ── internal: health factor ────────────────────────────────────────────

    function _healthFactor(address user) internal view returns (uint256) {
        uint256 collateralUSD = _actualDeposit(user, WETH) * priceOracle.getPrice(WETH) / 1e18;

        uint256 debtUSD = _actualDebt(user, USDC) * priceOracle.getPrice(USDC) / 1e6;

        if (debtUSD == 0) return type(uint256).max;

        return collateralUSD * reserves[WETH].liquidationThreshold / debtUSD;
    }

    // ── external functions (stubs — to be implemented) ────────────────────

    function deposit(address token, uint256 amount) external nonReentrant {
        // 1. validate
        //    - amount must be > 0
        //    - token must be WETH (only collateral accepted)
        //    - reserve must be active
        if (amount == 0) revert LendingPool__InvalidAmount();
        if (token != WETH) revert LendingPool__InvalidToken();
        if (!reserves[token].isActive) revert LendingPool__ReserveNotActive();

        // 2. update index (already stubbed)
        _updateReserveIndex(token);

        // 3. update user state
        //    - userDeposits[user][token] += amount
        userDeposits[msg.sender][token] += amount * RAY / reserves[token].depositIndex; // scale by depositIndex

        // 4. update reserve state
        //    - reserve.totalDeposits += amount
        reserves[token].totalDeposits += amount;

        // 5. transfer WETH from user → contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // 6. emit Deposit
        emit Deposit(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        // 1. validate
        if (amount == 0) revert LendingPool__InvalidAmount();
        if (token != WETH) revert LendingPool__InvalidToken();
        if (!reserves[token].isActive) revert LendingPool__ReserveNotActive();

        // 2. update index
        _updateReserveIndex(token);

        // 3.compute actual deposit — cap withdraw amount at full deposit so user can't overdraw
        uint256 actualDeposit = _actualDeposit(msg.sender, token);
        uint256 withdrawAmount = amount > actualDeposit ? actualDeposit : amount;

        // 4. compute scaled amount to reduce userDeposits
        userDeposits[msg.sender][token] -= withdrawAmount * RAY / reserves[token].depositIndex;

        // 5. reduce reserve.totalDeposits
        reserves[token].totalDeposits -= withdrawAmount;
        // 6. health factor check AFTER updating state — user can't withdraw so much that their remaining collateral can't cover their debt
        if (_healthFactor(msg.sender) < RAY) {
            revert LendingPool__InsufficientCollateral();
        }
        // 7. transfer WETH out to user
        IERC20(token).safeTransfer(msg.sender, withdrawAmount);

        // 8. emit Withdraw
        emit Withdraw(msg.sender, token, withdrawAmount);
    }

    function borrow(address token, uint256 amount) external nonReentrant {
        // 1. validate
        //    - amount > 0
        //    - token must be USDC (only borrowable asset)
        //    - reserve must be active
        if (amount == 0) revert LendingPool__InvalidAmount();
        if (token != USDC) revert LendingPool__InvalidToken();
        if (!reserves[token].isActive) revert LendingPool__ReserveNotActive();

        // 2. update index
        _updateReserveIndex(token);

        // 3. check pool has enough USDC liquidity
        //    reserve.totalDeposits - reserve.totalBorrows >= amount
        if (reserves[token].totalDeposits - reserves[token].totalBorrows < amount) {
            revert LendingPool__InsufficientLiquidity();
        }

        // 4. scale and update user borrow
        //    userBorrows[msg.sender][token] += amount * RAY / reserve.borrowIndex
        userBorrows[msg.sender][token] += amount * RAY / reserves[token].borrowIndex; // scale by borrowIndex

        // 5. update reserve
        //    reserve.totalBorrows += amount
        reserves[token].totalBorrows += amount;

        // 6. health factor check AFTER updating state
        //    if (_healthFactor(msg.sender) < RAY) revert
        if (_healthFactor(msg.sender) < RAY) {
            // revert if HF < 1.0
            revert LendingPool__InsufficientCollateral();
        }

        // 7. transfer USDC out to user
        IERC20(token).safeTransfer(msg.sender, amount);

        // 8. emit Borrow
        emit Borrow(msg.sender, token, amount);
    }

    function repay(address token, uint256 amount) external nonReentrant {
        // 1. validate amount > 0, token == USDC, reserve active
        if (amount == 0) revert LendingPool__InvalidAmount();
        if (token != USDC) revert LendingPool__InvalidToken();
        if (!reserves[token].isActive) revert LendingPool__ReserveNotActive();

        // 2. _updateReserveIndex(token)
        _updateReserveIndex(token);

        // 3. compute actual debt, cap repay amount at full debt so user can't overpay
        uint256 actualDebt = _actualDebt(msg.sender, token);
        uint256 repayAmount = amount > actualDebt ? actualDebt : amount;

        // 4. scale the capped amount and reduce userBorrows
        userBorrows[msg.sender][token] -= repayAmount * RAY / reserves[token].borrowIndex; // scale by borrowIndex

        // 5. reduce reserve.totalBorrows
        reserves[token].totalBorrows -= repayAmount;

        // 6. transfer USDC from user → contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);
        // emit Repay
        emit Repay(msg.sender, token, amount);
    }

    // ── external: view ────────────────────────────────────────────────────

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function actualDebt(address user, address token) external view returns (uint256) {
        return _actualDebt(user, token);
    }

    function actualDeposit(address user, address token) external view returns (uint256) {
        return _actualDeposit(user, token);
    }
}
