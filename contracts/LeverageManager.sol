// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function borrowBalanceOf(address account) external view returns (uint256);
    function collateralBalanceOf(address account, address asset) external view returns (uint256);
    function withdrawTo(address to, address asset, uint256 amount) external;
    function supplyTo(address to, address asset, uint256 amount) external;
    function borrow(uint256 amount) external;
}

interface IUniswapRouter {
    function exactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);
}

interface INAVOracle {
    function triggerUpdate() external;
    function getCbBTCPrice() external view returns (uint256);
}

interface IBTFD {
    function totalAssets() external view returns (uint256);
}

/**
 * @title LeverageManager
 * @notice Manages leveraged positions using Compound v3 for the BTFD vault on Base
 * @dev Leveraging occurs ONLY on deposit - no automatic rebalancing is performed
 */
contract LeverageManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // BTFD Vault (ERC-4626 compliant)
    address public btfdVault;
    // Compound v3 Comet contract
    address public compoundComet;
    // NAV Oracle
    address public navOracle;
    // Uniswap router for swaps
    address public uniswapRouter;
    
    // Token addresses
    address public cbBTCToken;
    address public usdcToken;
    
    // Target Loan-to-Value ratio (in basis points, e.g. 6500 = 65%)
    uint256 public targetLTV;
    
    // Maximum LTV before deleveraging (in basis points)
    uint256 public maxLTV;
    
    // Slippage tolerance for swaps (in basis points)
    uint256 public slippageTolerance;
    
    // UniswapV3 fee tier for swaps
    uint24 public uniswapFeeTier;
    
    event PositionLeveraged(uint256 collateralAmount, uint256 borrowAmount, uint256 newLTV);
    event PositionDeleveraged(uint256 repaidAmount, uint256 collateralReduced, uint256 newLTV);
    event LTVAdjusted(uint256 oldLTV, uint256 newLTV);
    event ExitPrepared(uint256 sharePercentage, uint256 cbBTCReturned);
    
    constructor(
        address _btfdVault,
        address _compoundComet,
        address _navOracle,
        address _uniswapRouter,
        address _cbBTCToken,
        address _usdcToken
    ) Ownable(msg.sender) {
        btfdVault = _btfdVault;
        compoundComet = _compoundComet;
        navOracle = _navOracle;
        uniswapRouter = _uniswapRouter;
        cbBTCToken = _cbBTCToken;
        usdcToken = _usdcToken;
        
        targetLTV = 6500; // 65%
        maxLTV = 7500; // 75%
        slippageTolerance = 100; // 1%
        uniswapFeeTier = 3000; // 0.3%
    }
    
    /**
     * @notice Get current position details
     * @return suppliedAmount Amount of cbBTC supplied as collateral
     * @return borrowedAmount Amount of USDC borrowed
     */
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount) {
        suppliedAmount = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        borrowedAmount = IComet(compoundComet).borrowBalanceOf(btfdVault);
        return (suppliedAmount, borrowedAmount);
    }
    
    /**
     * @notice Calculate current LTV ratio
     * @return LTV in basis points
     */
    function getCurrentLTV() public view returns (uint256) {
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        uint256 borrowedAmount = IComet(compoundComet).borrowBalanceOf(btfdVault);
        
        if (collateralValue == 0) {
            return 0;
        }
        
        // Get price of cbBTC in USDC from the oracle
        uint256 cbBTCPrice = INAVOracle(navOracle).getCbBTCPrice();
        
        uint256 collateralValueInUSDC = collateralValue * cbBTCPrice / 1e18;
        return borrowedAmount * 10000 / collateralValueInUSDC;
    }
    
    /**
     * @notice Handle new deposit by applying leverage ONCE at entry
     * @param amount Amount of new cbBTC collateral
     */
    function onDeposit(uint256 amount) external nonReentrant {
        // Only vault can call this
        require(msg.sender == btfdVault, "Only vault can call");
        
        // Supply new collateral to Compound
        IERC20(cbBTCToken).safeTransferFrom(btfdVault, address(this), amount);
        IERC20(cbBTCToken).approve(compoundComet, amount);
        IComet(compoundComet).supplyTo(btfdVault, cbBTCToken, amount);
        
        // Apply leverage once at entry to target LTV
        _applyEntryLeverage();
        
        // Update NAV
        INAVOracle(navOracle).triggerUpdate();
    }
    
    /**
     * @notice Prepare exit by unwinding part of leverage
     * @param sharePercentage Percentage of total to exit (in basis points)
     * @return cbBTCAmount Amount of cbBTC released for exit
     */
    function prepareExit(uint256 sharePercentage) external nonReentrant returns (uint256 cbBTCAmount) {
        // Only vault can call this
        require(msg.sender == btfdVault, "Only vault can call");
        require(sharePercentage > 0 && sharePercentage <= 10000, "Invalid percentage");
        
        // Get current position
        uint256 totalCollateral = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        uint256 totalBorrowed = IComet(compoundComet).borrowBalanceOf(btfdVault);
        
        // Calculate amounts to unwind
        uint256 collateralToWithdraw = totalCollateral * sharePercentage / 10000;
        uint256 debtToRepay = totalBorrowed * sharePercentage / 10000;
        
        // If there's no position to unwind
        if (totalCollateral == 0 || totalBorrowed == 0) {
            return 0;
        }
        
        // First, withdraw cbBTC from Compound to handle the debt repayment
        uint256 cbBTCToSwap = _calculateCbBTCToSwapForUSDC(debtToRepay);
        
        // Make sure we don't try to withdraw more than we have
        cbBTCToSwap = cbBTCToSwap > collateralToWithdraw ? collateralToWithdraw : cbBTCToSwap;
        
        if (cbBTCToSwap > 0) {
            // Withdraw cbBTC from Compound
            IComet(compoundComet).withdrawTo(address(this), cbBTCToken, cbBTCToSwap);
            
            // Swap cbBTC for USDC
            IERC20(cbBTCToken).approve(uniswapRouter, cbBTCToSwap);
            uint256 minUSDC = debtToRepay * (10000 - slippageTolerance) / 10000; // Account for slippage
            
            uint256 receivedUSDC = IUniswapRouter(uniswapRouter).exactInputSingle(
                cbBTCToken,
                usdcToken,
                uniswapFeeTier,
                address(this),
                cbBTCToSwap,
                minUSDC,
                0 // No price limit
            );
            
            // Repay debt to Compound
            IERC20(usdcToken).approve(compoundComet, receivedUSDC);
            IComet(compoundComet).supply(usdcToken, receivedUSDC);
            
            // Reduce collateral to withdraw by the amount swapped
            collateralToWithdraw = collateralToWithdraw > cbBTCToSwap ? 
                                   collateralToWithdraw - cbBTCToSwap : 0;
        }
        
        // Withdraw remaining collateral directly to the vault
        if (collateralToWithdraw > 0) {
            IComet(compoundComet).withdrawTo(btfdVault, cbBTCToken, collateralToWithdraw);
            cbBTCAmount = collateralToWithdraw;
        }
        
        // Update NAV
        INAVOracle(navOracle).triggerUpdate();
        
        emit ExitPrepared(sharePercentage, cbBTCAmount);
        
        return cbBTCAmount;
    }
    
    /**
     * @notice Calculate how much cbBTC to swap to get a target amount of USDC
     * @param usdcAmount Target USDC amount
     * @return Amount of cbBTC to swap
     */
    function _calculateCbBTCToSwapForUSDC(uint256 usdcAmount) internal view returns (uint256) {
        // Get price of cbBTC in USDC from the oracle
        uint256 cbBTCPrice = INAVOracle(navOracle).getCbBTCPrice();
        
        // Add some buffer for slippage and fees
        uint256 buffer = slippageTolerance * 2; // Double the slippage tolerance for safety
        
        // Calculate cbBTC amount needed
        return usdcAmount * (10000 + buffer) / 10000 * 1e18 / cbBTCPrice;
    }
    
    /**
     * @notice Apply leverage to the position at entry
     * @dev This only happens once when assets are deposited, not continuously
     */
    function _applyEntryLeverage() internal {
        uint256 currentLTV = getCurrentLTV();
        
        if (currentLTV < targetLTV) {
            // Leverage up: borrow more
            _leverageUp();
        } else if (currentLTV > maxLTV) {
            // If LTV is too high (unlikely on entry), deleverage
            _deleverageDown();
        }
        
        // Update NAV after adjustment
        INAVOracle(navOracle).triggerUpdate();
    }
    
    /**
     * @notice Increase leverage by borrowing more and buying more collateral
     */
    function _leverageUp() internal {
        // Get current position
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        uint256 currentBorrowed = IComet(compoundComet).borrowBalanceOf(btfdVault);
        
        // Get price of cbBTC in USDC
        uint256 cbBTCPrice = INAVOracle(navOracle).getCbBTCPrice();
        
        uint256 collateralValueInUSDC = collateralValue * cbBTCPrice / 1e18;
        
        // Calculate how much more to borrow to reach target LTV
        uint256 targetBorrow = collateralValueInUSDC * targetLTV / 10000;
        uint256 additionalBorrow = targetBorrow > currentBorrowed ? 
                                 targetBorrow - currentBorrowed : 0;
        
        if (additionalBorrow > 0) {
            // Borrow more USDC
            IComet(compoundComet).borrow(additionalBorrow);
            
            // Swap USDC for more cbBTC
            IERC20(usdcToken).approve(uniswapRouter, additionalBorrow);
            
            // Calculate minimum cbBTC expected (accounting for slippage)
            uint256 expectedCbBTC = additionalBorrow * 1e18 / cbBTCPrice;
            uint256 minCbBTC = expectedCbBTC * (10000 - slippageTolerance) / 10000;
            
            uint256 receivedCbBTC = IUniswapRouter(uniswapRouter).exactInputSingle(
                usdcToken,
                cbBTCToken,
                uniswapFeeTier,
                address(this),
                additionalBorrow,
                minCbBTC,
                0 // No price limit
            );
            
            // Supply new cbBTC as collateral
            IERC20(cbBTCToken).approve(compoundComet, receivedCbBTC);
            IComet(compoundComet).supplyTo(btfdVault, cbBTCToken, receivedCbBTC);
            
            emit PositionLeveraged(receivedCbBTC, additionalBorrow, getCurrentLTV());
        }
    }
    
    /**
     * @notice Reduce leverage by selling collateral to repay debt
     */
    function _deleverageDown() internal {
        uint256 currentLTV = getCurrentLTV();
        
        if (currentLTV <= targetLTV) {
            return; // Already at or below target
        }
        
        // Get current position
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        uint256 currentBorrowed = IComet(compoundComet).borrowBalanceOf(btfdVault);
        
        // Get price of cbBTC in USDC
        uint256 cbBTCPrice = INAVOracle(navOracle).getCbBTCPrice();
        
        uint256 collateralValueInUSDC = collateralValue * cbBTCPrice / 1e18;
        
        // Calculate how much debt to repay to reach target LTV
        uint256 targetBorrow = collateralValueInUSDC * targetLTV / 10000;
        uint256 amountToRepay = currentBorrowed > targetBorrow ? 
                              currentBorrowed - targetBorrow : 0;
        
        if (amountToRepay > 0) {
            // Calculate cbBTC to sell
            uint256 cbBTCToSell = _calculateCbBTCToSwapForUSDC(amountToRepay);
            
            // Withdraw cbBTC from Compound
            IComet(compoundComet).withdrawTo(address(this), cbBTCToken, cbBTCToSell);
            
            // Swap cbBTC for USDC
            IERC20(cbBTCToken).approve(uniswapRouter, cbBTCToSell);
            uint256 minUSDC = amountToRepay * (10000 - slippageTolerance) / 10000;
            
            uint256 receivedUSDC = IUniswapRouter(uniswapRouter).exactInputSingle(
                cbBTCToken,
                usdcToken,
                uniswapFeeTier,
                address(this),
                cbBTCToSell,
                minUSDC,
                0 // No price limit
            );
            
            // Repay debt
            IERC20(usdcToken).approve(compoundComet, receivedUSDC);
            IComet(compoundComet).supply(usdcToken, receivedUSDC);
            
            emit PositionDeleveraged(receivedUSDC, cbBTCToSell, getCurrentLTV());
        }
    }
    
    /**
     * @notice Manual rebalance function - not used in normal operation
     * @dev Can be called by vault or owner for emergency situations only
     */
    function rebalance() external {
        require(msg.sender == btfdVault || msg.sender == owner(), "Unauthorized");
        
        uint256 oldLTV = getCurrentLTV();
        _applyEntryLeverage();
        uint256 newLTV = getCurrentLTV();
        
        emit LTVAdjusted(oldLTV, newLTV);
    }
    
    /**
     * @notice Get the current health factor of the position
     * @return Health factor in percentage (10000 = 100%)
     */
    function getHealthFactor() external view returns (uint256) {
        uint256 currentLTV = getCurrentLTV();
        if (currentLTV == 0) return type(uint256).max; // No debt = infinite health
        
        // Calculate how much room we have before max LTV (higher is better)
        uint256 liquidationLTV = 8500; // Assuming Compound liquidation starts at 85% LTV
        
        if (currentLTV >= liquidationLTV) return 0; // Already liquidatable
        
        return (liquidationLTV - currentLTV) * 10000 / currentLTV;
    }
    
    /**
     * @notice Set target LTV
     * @param _targetLTV New target LTV in basis points
     */
    function setTargetLTV(uint256 _targetLTV) external onlyOwner {
        require(_targetLTV > 0 && _targetLTV < maxLTV, "Invalid target LTV");
        targetLTV = _targetLTV;
    }
    
    /**
     * @notice Set maximum LTV before deleveraging
     * @param _maxLTV New max LTV in basis points
     */
    function setMaxLTV(uint256 _maxLTV) external onlyOwner {
        require(_maxLTV > targetLTV, "Max LTV must be higher than target");
        maxLTV = _maxLTV;
    }
    
    /**
     * @notice Set slippage tolerance for swaps
     * @param _slippageTolerance New slippage tolerance in basis points
     */
    function setSlippageTolerance(uint256 _slippageTolerance) external onlyOwner {
        require(_slippageTolerance < 1000, "Slippage too high"); // Max 10%
        slippageTolerance = _slippageTolerance;
    }
    
    /**
     * @notice Set Uniswap fee tier
     * @param _uniswapFeeTier New fee tier
     */
    function setUniswapFeeTier(uint24 _uniswapFeeTier) external onlyOwner {
        uniswapFeeTier = _uniswapFeeTier;
    }
    
    /**
     * @notice Update contract addresses
     * @param _btfdVault New vault address
     * @param _compoundComet New Compound Comet address
     * @param _navOracle New NAV oracle address
     * @param _uniswapRouter New Uniswap router address
     */
    function updateAddresses(
        address _btfdVault,
        address _compoundComet,
        address _navOracle,
        address _uniswapRouter
    ) external onlyOwner {
        if (_btfdVault != address(0)) btfdVault = _btfdVault;
        if (_compoundComet != address(0)) compoundComet = _compoundComet;
        if (_navOracle != address(0)) navOracle = _navOracle;
        if (_uniswapRouter != address(0)) uniswapRouter = _uniswapRouter;
    }
    
    /**
     * @notice Update token addresses
     * @param _cbBTCToken New cbBTC token address
     * @param _usdcToken New USDC token address
     */
    function updateTokenAddresses(
        address _cbBTCToken,
        address _usdcToken
    ) external onlyOwner {
        if (_cbBTCToken != address(0)) cbBTCToken = _cbBTCToken;
        if (_usdcToken != address(0)) usdcToken = _usdcToken;
    }
    
    /**
     * @notice Emergency function to withdraw all tokens in case of critical issues
     * @dev Only owner can call this
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 cbBTCBalance = IERC20(cbBTCToken).balanceOf(address(this));
        if (cbBTCBalance > 0) {
            IERC20(cbBTCToken).safeTransfer(btfdVault, cbBTCBalance);
        }
        
        uint256 usdcBalance = IERC20(usdcToken).balanceOf(address(this));
        if (usdcBalance > 0) {
            IERC20(usdcToken).safeTransfer(btfdVault, usdcBalance);
        }
    }
    
    /**
     * @notice Emergency function to force deleverage in extreme market conditions
     * @param targetLTVBps Target LTV in basis points to reduce to
     */
    function emergencyDeleverage(uint256 targetLTVBps) external onlyOwner {
        require(targetLTVBps < getCurrentLTV(), "Target must be lower than current LTV");
        
        uint256 oldLTV = getCurrentLTV();
        uint256 oldTargetLTV = targetLTV;
        
        // Temporarily set target LTV to the emergency target
        targetLTV = targetLTVBps;
        
        // Force deleverage
        _deleverageDown();
        
        // Restore original target
        targetLTV = oldTargetLTV;
        
        emit LTVAdjusted(oldLTV, getCurrentLTV());
    }
}