// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

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
}

/**
 * @title LeverageManager
 * @notice Manages leveraged positions using Compound v3
 */
contract LeverageManager is Ownable, ReentrancyGuard {
    // Treasury (Gnosis Safe)
    address public treasury;
    // Compound v3 Comet contract
    address public compoundComet;
    // NAV Oracle
    address public navOracle;
    // Uniswap router for swaps
    address public uniswapRouter;
    
    // Token addresses
    address public fbtcToken;
    address public usdeToken;
    
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
    
    constructor(
        address _treasury,
        address _compoundComet,
        address _navOracle,
        address _uniswapRouter,
        address _fbtcToken,
        address _usdeToken
    ) Ownable(msg.sender) {
        treasury = _treasury;
        compoundComet = _compoundComet;
        navOracle = _navOracle;
        uniswapRouter = _uniswapRouter;
        fbtcToken = _fbtcToken;
        usdeToken = _usdeToken;
        
        targetLTV = 6500; // 65%
        maxLTV = 7500; // 75%
        slippageTolerance = 100; // 1%
        uniswapFeeTier = 3000; // 0.3%
    }
    
    /**
     * @notice Get current position details
     * @return suppliedAmount Amount of FBTC supplied as collateral
     * @return borrowedAmount Amount of USDe borrowed
     */
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount) {
        suppliedAmount = IComet(compoundComet).collateralBalanceOf(treasury, fbtcToken);
        borrowedAmount = IComet(compoundComet).borrowBalanceOf(treasury);
        return (suppliedAmount, borrowedAmount);
    }
    
    /**
     * @notice Calculate current LTV ratio
     * @return LTV in basis points
     */
    function getCurrentLTV() public view returns (uint256) {
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(treasury, fbtcToken);
        uint256 borrowedAmount = IComet(compoundComet).borrowBalanceOf(treasury);
        
        if (collateralValue == 0) {
            return 0;
        }
        
        // Get price of FBTC in USDe
        // This is simplified - would need an actual price oracle
        uint256 fbtcPrice = 80000 * 1e18; // Example: 80k USDe per FBTC
        
        uint256 collateralValueInUSDe = collateralValue * fbtcPrice / 1e18;
        return borrowedAmount * 10000 / collateralValueInUSDe;
    }
    
    /**
     * @notice Handle new deposit by adjusting leverage
     * @param newCollateralAmount Amount of new FBTC collateral
     */
    function onDeposit(uint256 newCollateralAmount) external nonReentrant {
        // Only treasury can call this
        require(msg.sender == treasury, "Only treasury can call");
        
        // Supply new collateral to Compound
        IERC20(fbtcToken).transferFrom(treasury, address(this), newCollateralAmount);
        IERC20(fbtcToken).approve(compoundComet, newCollateralAmount);
        IComet(compoundComet).supplyTo(treasury, fbtcToken, newCollateralAmount);
        
        // Adjust leverage to target LTV
        _adjustLeverage();
        
        // Update NAV
        INAVOracle(navOracle).triggerUpdate();
    }
    
    /**
     * @notice Prepare exit by unwinding part of leverage
     * @param sharePercentage Percentage of total to exit (in basis points)
     * @return fbtcAmount Amount of FBTC released for exit
     */
    function prepareExit(uint256 sharePercentage) external nonReentrant returns (uint256 fbtcAmount) {
        // Only treasury can call this
        require(msg.sender == treasury, "Only treasury can call");
        require(sharePercentage > 0 && sharePercentage <= 10000, "Invalid percentage");
        
        // Get current position
        uint256 totalCollateral = IComet(compoundComet).collateralBalanceOf(treasury, fbtcToken);
        uint256 totalBorrowed = IComet(compoundComet).borrowBalanceOf(treasury);
        
        // Calculate amounts to unwind
        uint256 collateralToWithdraw = totalCollateral * sharePercentage / 10000;
        uint256 debtToRepay = totalBorrowed * sharePercentage / 10000;
        
        // Repay portion of debt
        // First get USDe (either from treasury or by swapping FBTC)
        if (IERC20(usdeToken).balanceOf(treasury) >= debtToRepay) {
            // If treasury has enough USDe, use that
            IERC20(usdeToken).transferFrom(treasury, address(this), debtToRepay);
        } else {
            // Otherwise, withdraw some FBTC and swap for USDe
            uint256 fbtcToSwap = _calculateFbtcToSwapForUsde(debtToRepay);
            
            // Withdraw FBTC from Compound
            IComet(compoundComet).withdrawTo(address(this), fbtcToken, fbtcToSwap);
            
            // Swap FBTC for USDe
            IERC20(fbtcToken).approve(uniswapRouter, fbtcToSwap);
            uint256 minUsDe = debtToRepay * (10000 - slippageTolerance) / 10000; // Account for slippage
            
            uint256 receivedUSDe = IUniswapRouter(uniswapRouter).exactInputSingle(
                fbtcToken,
                usdeToken,
                uniswapFeeTier,
                address(this),
                fbtcToSwap,
                minUsDe,
                0 // No price limit
            );
            
            require(receivedUSDe >= debtToRepay, "Swap didn't yield enough USDe");
            
            // Reduce collateral to withdraw by the amount swapped
            collateralToWithdraw = collateralToWithdraw > fbtcToSwap ? 
                                   collateralToWithdraw - fbtcToSwap : 0;
        }
        
        // Repay debt to Compound
        IERC20(usdeToken).approve(compoundComet, debtToRepay);
        IComet(compoundComet).supply(usdeToken, debtToRepay);
        
        // Withdraw remaining collateral
        if (collateralToWithdraw > 0) {
            IComet(compoundComet).withdrawTo(treasury, fbtcToken, collateralToWithdraw);
            fbtcAmount = collateralToWithdraw;
        }
        
        // Update NAV
        INAVOracle(navOracle).triggerUpdate();
        
        return fbtcAmount;
    }
    
    /**
     * @notice Calculate how much FBTC to swap to get a target amount of USDe
     * @param usdeAmount Target USDe amount
     * @return Amount of FBTC to swap
     */
    function _calculateFbtcToSwapForUsde(uint256 usdeAmount) internal view returns (uint256) {
        // Get price of FBTC in USDe
        // This is simplified - would need an actual price oracle
        uint256 fbtcPrice = 80000 * 1e18; // Example: 80k USDe per FBTC
        
        // Add some buffer for slippage and fees (e.g., 2%)
        uint256 buffer = 200;
        
        // Calculate FBTC amount needed
        return usdeAmount * (10000 + buffer) / 10000 * 1e18 / fbtcPrice;
    }
    
    /**
     * @notice Adjust leverage to maintain target LTV
     */
    function _adjustLeverage() internal {
        uint256 currentLTV = getCurrentLTV();
        
        if (currentLTV < targetLTV) {
            // Leverage up: borrow more
            _leverageUp();
        } else if (currentLTV > maxLTV) {
            // Deleverage: repay some debt
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
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(treasury, fbtcToken);
        uint256 currentBorrowed = IComet(compoundComet).borrowBalanceOf(treasury);
        
        // Get price of FBTC in USDe
        // This is simplified - would need an actual price oracle
        uint256 fbtcPrice = 80000 * 1e18; // Example: 80k USDe per FBTC
        
        uint256 collateralValueInUSDe = collateralValue * fbtcPrice / 1e18;
        
        // Calculate how much more to borrow to reach target LTV
        uint256 targetBorrow = collateralValueInUSDe * targetLTV / 10000;
        uint256 additionalBorrow = targetBorrow > currentBorrowed ? 
                                 targetBorrow - currentBorrowed : 0;
        
        if (additionalBorrow > 0) {
            // Borrow more USDe
            IComet(compoundComet).borrow(additionalBorrow);
            
            // Swap USDe for more FBTC
            IERC20(usdeToken).approve(uniswapRouter, additionalBorrow);
            
            // Calculate minimum FBTC expected (accounting for slippage)
            uint256 expectedFbtc = additionalBorrow * 1e18 / fbtcPrice;
            uint256 minFbtc = expectedFbtc * (10000 - slippageTolerance) / 10000;
            
            uint256 receivedFBTC = IUniswapRouter(uniswapRouter).exactInputSingle(
                usdeToken,
                fbtcToken,
                uniswapFeeTier,
                address(this),
                additionalBorrow,
                minFbtc,
                0 // No price limit
            );
            
            // Supply new FBTC as collateral
            IERC20(fbtcToken).approve(compoundComet, receivedFBTC);
            IComet(compoundComet).supplyTo(treasury, fbtcToken, receivedFBTC);
            
            emit PositionLeveraged(receivedFBTC, additionalBorrow, getCurrentLTV());
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
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(treasury, fbtcToken);
        uint256 currentBorrowed = IComet(compoundComet).borrowBalanceOf(treasury);
        
        // Get price of FBTC in USDe
        // This is simplified - would need an actual price oracle
        uint256 fbtcPrice = 80000 * 1e18; // Example: 80k USDe per FBTC
        
        uint256 collateralValueInUSDe = collateralValue * fbtcPrice / 1e18;
        
        // Calculate how much debt to repay to reach target LTV
        uint256 targetBorrow = collateralValueInUSDe * targetLTV / 10000;
        uint256 amountToRepay = currentBorrowed > targetBorrow ? 
                              currentBorrowed - targetBorrow : 0;
        
        if (amountToRepay > 0) {
            // Calculate FBTC to sell
            uint256 fbtcToSell = _calculateFbtcToSwapForUsde(amountToRepay);
            
            // Withdraw FBTC from Compound
            IComet(compoundComet).withdrawTo(address(this), fbtcToken, fbtcToSell);
            
            // Swap FBTC for USDe
            IERC20(fbtcToken).approve(uniswapRouter, fbtcToSell);
            uint256 minUsDe = amountToRepay * (10000 - slippageTolerance) / 10000;
            
            uint256 receivedUSDe = IUniswapRouter(uniswapRouter).exactInputSingle(
                fbtcToken,
                usdeToken,
                uniswapFeeTier,
                address(this),
                fbtcToSell,
                minUsDe,
                0 // No price limit
            );
            
            // Repay debt
            IERC20(usdeToken).approve(compoundComet, receivedUSDe);
            IComet(compoundComet).supply(usdeToken, receivedUSDe);
            
            emit PositionDeleveraged(receivedUSDe, fbtcToSell, getCurrentLTV());
        }
    }
    
    /**
     * @notice Manually trigger leverage adjustment
     * @dev Can be called by treasury or owner
     */
    function rebalance() external {
        require(msg.sender == treasury || msg.sender == owner(), "Unauthorized");
        
        uint256 oldLTV = getCurrentLTV();
        _adjustLeverage();
        uint256 newLTV = getCurrentLTV();
        
        emit LTVAdjusted(oldLTV, newLTV);
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
     * @param _treasury New treasury address
     * @param _compoundComet New Compound Comet address
     * @param _navOracle New NAV oracle address
     * @param _uniswapRouter New Uniswap router address
     */
    function updateAddresses(
        address _treasury,
        address _compoundComet,
        address _navOracle,
        address _uniswapRouter
    ) external onlyOwner {
        treasury = _treasury;
        compoundComet = _compoundComet;
        navOracle = _navOracle;
        uniswapRouter = _uniswapRouter;
    }
    
    /**
     * @notice Update token addresses
     * @param _fbtcToken New FBTC token address
     * @param _usdeToken New USDe token address
     */
    function updateTokenAddresses(
        address _fbtcToken,
        address _usdeToken
    ) external onlyOwner {
        fbtcToken = _fbtcToken;
        usdeToken = _usdeToken;
    }
    
    /**
     * @notice Emergency function to withdraw all tokens in case of critical issues
     * @dev Only owner can call this
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 fbtcBalance = IERC20(fbtcToken).balanceOf(address(this));
        if (fbtcBalance > 0) {
            IERC20(fbtcToken).transfer(treasury, fbtcBalance);
        }
        
        uint256 usdeBalance = IERC20(usdeToken).balanceOf(address(this));
        if (usdeBalance > 0) {
            IERC20(usdeToken).transfer(treasury, usdeBalance);
        }
    }
}