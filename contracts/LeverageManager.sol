// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @dev Interface for interacting with Compound III's Comet contract
 * Comet is Compound's core lending protocol that allows supplying collateral and borrowing
 */
interface IComet {
    /**
     * @notice Supply an asset to the protocol (debt repayment)
     * @param asset Token address to supply
     * @param amount Amount to supply
     */
    function supply(address asset, uint256 amount) external;
    
    /**
     * @notice Withdraw an asset from the protocol
     * @param asset Token address to withdraw
     * @param amount Amount to withdraw
     */
    function withdraw(address asset, uint256 amount) external;
    
    /**
     * @notice Get the current borrow balance of an account
     * @param account Address to check
     * @return Current debt amount
     */
    function borrowBalanceOf(address account) external view returns (uint256);
    
    /**
     * @notice Get the current collateral balance of an account for a specific asset
     * @param account Address to check
     * @param asset Asset to check
     * @return Current collateral amount
     */
    function collateralBalanceOf(address account, address asset) external view returns (uint256);
    
    /**
     * @notice Withdraw an asset directly to a specified recipient
     * @param to Recipient address
     * @param asset Asset to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawTo(address to, address asset, uint256 amount) external;
    
    /**
     * @notice Supply an asset directly from a specific account
     * @param to Account that will own the supplied assets
     * @param asset Asset to supply
     * @param amount Amount to supply
     */
    function supplyTo(address to, address asset, uint256 amount) external;
    
    /**
     * @notice Borrow funds from the protocol
     * @param amount Amount to borrow
     */
    function borrow(uint256 amount) external;
}

/**
 * @dev Interface for interacting with Uniswap V3 Router for token swaps
 * Simplified interface with just the exactInputSingle function
 */
interface IUniswapRouter {
    /**
     * @notice Swaps an exact amount of input token for as much output token as possible
     * @param tokenIn Address of input token
     * @param tokenOut Address of output token
     * @param fee Pool fee (in hundredths of a bip, e.g., 3000 = 0.3%)
     * @param recipient Recipient of the output tokens
     * @param amountIn Amount of input tokens to send
     * @param amountOutMinimum Minimum amount of output tokens that must be received
     * @param sqrtPriceLimitX96 Price limit (0 for no limit)
     * @return amountOut Amount of output tokens received
     */
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

/**
 * @dev Interface for the NAV Oracle that provides pricing data
 */
interface INAVOracle {
    /**
     * @notice Triggers an update of the oracle's price data
     */
    function triggerUpdate() external;
    
    /**
     * @notice Gets the current price of cbBTC in USDC
     * @return Current price with 18 decimals of precision
     */
    function getCbBTCPrice() external view returns (uint256);
}

/**
 * @dev Interface for interacting with the BTFD vault
 */
interface IBTFD {
    /**
     * @notice Gets the total assets managed by the vault
     * @return Total value of assets in the vault
     */
    function totalAssets() external view returns (uint256);
}

/**
 * @title LeverageManager
 * @notice Manages leveraged positions on Compound III for the BTFD vault on Base network
 * 
 * This contract enables the BTFD vault to create and manage leveraged long positions on Bitcoin via cbBTC.
 * The leveraging strategy works as follows:
 * 
 * 1. Deposit cbBTC as collateral to Compound III
 * 2. Borrow USDC against the collateral
 * 3. Swap the borrowed USDC for more cbBTC using Uniswap V3
 * 4. Deposit the additional cbBTC as collateral to Compound III
 * 5. Repeat steps 2-4 until target leverage is achieved
 * 
 * Key features:
 * - Leverage is applied ONLY on deposit, not continuously (no auto-rebalancing)
 * - Target LTV of 65% with a maximum of 75% before deleveraging
 * - Proportional unwinding of positions when users withdraw from the vault
 * - Emergency functions for risk management
 */
contract LeverageManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    //----------------------------------------------------------------
    // STATE VARIABLES
    //----------------------------------------------------------------
    
    /**
     * @notice Address of the BTFD vault using this leverage manager
     * @dev This is the only contract authorized to call key functions
     */
    address public btfdVault;
    
    /**
     * @notice Address of Compound III's Comet contract on Base
     * @dev This is the main lending protocol used for leverage
     */
    address public compoundComet;
    
    /**
     * @notice Address of the NAV Oracle that provides cbBTC price data
     */
    address public navOracle;
    
    /**
     * @notice Address of Uniswap V3 Router for token swaps
     */
    address public uniswapRouter;
    
    /**
     * @notice Address of the cbBTC token (Bitcoin on Base)
     * @dev This is used as collateral in Compound III
     */
    address public cbBTCToken;
    
    /**
     * @notice Address of the USDC token
     * @dev This is the borrowed asset in Compound III
     */
    address public usdcToken;
    
    /**
     * @notice Target Loan-to-Value ratio for the leveraged position
     * @dev Expressed in basis points (e.g., 6500 = 65%)
     * This represents the optimal debt-to-collateral ratio for the strategy
     */
    uint256 public targetLTV;
    
    /**
     * @notice Maximum LTV before forced deleveraging
     * @dev Expressed in basis points (e.g., 7500 = 75%)
     * If LTV exceeds this value, the position will be partially unwound
     */
    uint256 public maxLTV;
    
    /**
     * @notice Slippage tolerance for swaps
     * @dev Expressed in basis points (e.g., 100 = 1%)
     * Used to calculate minimum output when swapping tokens
     */
    uint256 public slippageTolerance;
    
    /**
     * @notice Uniswap V3 fee tier for swaps
     * @dev Fee in hundredths of a bip (e.g., 3000 = 0.3%)
     */
    uint24 public uniswapFeeTier;
    
    /**
     * @notice Emitted when a position is leveraged up
     * @param collateralAmount Amount of new collateral added
     * @param borrowAmount Amount of USDC borrowed
     * @param newLTV New LTV after leveraging
     */
    event PositionLeveraged(uint256 collateralAmount, uint256 borrowAmount, uint256 newLTV);
    
    /**
     * @notice Emitted when a position is deleveraged
     * @param repaidAmount Amount of debt repaid
     * @param collateralReduced Amount of collateral reduced
     * @param newLTV New LTV after deleveraging
     */
    event PositionDeleveraged(uint256 repaidAmount, uint256 collateralReduced, uint256 newLTV);
    
    /**
     * @notice Emitted when LTV ratio is adjusted
     * @param oldLTV Previous LTV
     * @param newLTV New LTV
     */
    event LTVAdjusted(uint256 oldLTV, uint256 newLTV);
    
    /**
     * @notice Emitted when a portion of the position is unwound for withdrawal
     * @param sharePercentage Percentage of position unwound (in basis points)
     * @param cbBTCReturned Amount of cbBTC returned to the vault
     */
    event ExitPrepared(uint256 sharePercentage, uint256 cbBTCReturned);
    
    //----------------------------------------------------------------
    // CONSTRUCTOR & SETUP
    //----------------------------------------------------------------
    
    /**
     * @notice Initialize the LeverageManager with required addresses and default settings
     * @param _btfdVault Address of the BTFD vault
     * @param _compoundComet Address of Compound III's Comet contract
     * @param _navOracle Address of the price oracle
     * @param _uniswapRouter Address of Uniswap V3 Router
     * @param _cbBTCToken Address of cbBTC token
     * @param _usdcToken Address of USDC token
     * @dev Sets default parameters for the leverage strategy:
     *   - Target LTV: 65% (6500 basis points)
     *   - Max LTV: 75% (7500 basis points)
     *   - Slippage tolerance: 1% (100 basis points)
     *   - Uniswap fee tier: 0.3% (3000 hundredths of a bip)
     */
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
    
    //----------------------------------------------------------------
    // POSITION INFORMATION FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Get current position details from Compound III
     * @return suppliedAmount Amount of cbBTC supplied as collateral
     * @return borrowedAmount Amount of USDC borrowed
     * @dev This function is called by the BTFD vault to calculate total assets
     * and determine the NAV per share
     */
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount) {
        suppliedAmount = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        borrowedAmount = IComet(compoundComet).borrowBalanceOf(btfdVault);
        return (suppliedAmount, borrowedAmount);
    }
    
    /**
     * @notice Calculate current Loan-to-Value ratio of the position
     * @return LTV in basis points (e.g., 6500 = 65%)
     * @dev Formula: (borrowed amount / collateral value in USDC) * 10000
     * This is a key metric for monitoring the health of the leveraged position
     */
    function getCurrentLTV() public view returns (uint256) {
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        uint256 borrowedAmount = IComet(compoundComet).borrowBalanceOf(btfdVault);
        
        if (collateralValue == 0) {
            return 0;
        }
        
        // Get price of cbBTC in USDC from the oracle
        uint256 cbBTCPrice = INAVOracle(navOracle).getCbBTCPrice();
        
        // Convert cbBTC collateral to USDC value
        uint256 collateralValueInUSDC = collateralValue * cbBTCPrice / 1e18;
        
        // Calculate LTV in basis points
        return borrowedAmount * 10000 / collateralValueInUSDC;
    }
    
    /**
     * @notice Get the current health factor of the position
     * @return Health factor in percentage (10000 = 100%)
     * @dev Higher values indicate healthier positions. Formula:
     * (liquidation LTV - current LTV) * 10000 / current LTV
     * Returns max uint if there's no debt (infinite health)
     */
    function getHealthFactor() external view returns (uint256) {
        uint256 currentLTV = getCurrentLTV();
        if (currentLTV == 0) return type(uint256).max; // No debt = infinite health
        
        // Calculate how much room we have before liquidation (higher is better)
        uint256 liquidationLTV = 8500; // Assuming Compound liquidation starts at 85% LTV
        
        if (currentLTV >= liquidationLTV) return 0; // Already liquidatable
        
        return (liquidationLTV - currentLTV) * 10000 / currentLTV;
    }
    
    //----------------------------------------------------------------
    // DEPOSIT AND LEVERAGE FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Handle new deposits by applying leverage
     * @param amount Amount of new cbBTC collateral
     * @dev This function is called by the BTFD vault when a user deposits
     * Workflow:
     * 1. Transfer cbBTC from vault to this contract
     * 2. Supply cbBTC to Compound III as collateral for the vault
     * 3. Leverage up to target LTV by borrowing USDC and buying more cbBTC
     * 4. Trigger NAV update to reflect new position value
     */
    function onDeposit(uint256 amount) external nonReentrant {
        // Only vault can call this
        require(msg.sender == btfdVault, "Only vault can call");
        
        // Transfer cbBTC from vault to this contract
        IERC20(cbBTCToken).safeTransferFrom(btfdVault, address(this), amount);
        
        // Approve and supply cbBTC to Compound III
        IERC20(cbBTCToken).approve(compoundComet, amount);
        IComet(compoundComet).supplyTo(btfdVault, cbBTCToken, amount);
        
        // Apply leverage once at entry to target LTV
        _applyEntryLeverage();
        
        // Update NAV to reflect the new position value
        INAVOracle(navOracle).triggerUpdate();
    }
    
    /**
     * @notice Apply leverage to the position upon deposit
     * @dev This is called only once when assets are deposited, not continuously
     * It either leverages up (if below target LTV) or deleverages down (if above max LTV)
     */
    function _applyEntryLeverage() internal {
        uint256 currentLTV = getCurrentLTV();
        
        if (currentLTV < targetLTV) {
            // Leverage up: borrow more USDC and buy more cbBTC
            _leverageUp();
        } else if (currentLTV > maxLTV) {
            // If LTV is too high (unlikely on entry), deleverage
            _deleverageDown();
        }
        
        // Update NAV after adjustment
        INAVOracle(navOracle).triggerUpdate();
    }
    
    /**
     * @notice Increase leverage by borrowing more USDC and buying more cbBTC
     * @dev Internal implementation of the leveraging strategy:
     * 1. Calculate additional USDC to borrow to reach target LTV
     * 2. Borrow USDC from Compound III
     * 3. Swap USDC for cbBTC on Uniswap V3
     * 4. Supply the new cbBTC as additional collateral
     * The end result is increased exposure to Bitcoin price movements
     */
    function _leverageUp() internal {
        // Get current position details
        uint256 collateralValue = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        uint256 currentBorrowed = IComet(compoundComet).borrowBalanceOf(btfdVault);
        
        // Get price of cbBTC in USDC
        uint256 cbBTCPrice = INAVOracle(navOracle).getCbBTCPrice();
        
        // Calculate collateral value in USDC
        uint256 collateralValueInUSDC = collateralValue * cbBTCPrice / 1e18;
        
        // Calculate how much more USDC to borrow to reach target LTV
        // Formula: (collateral value * target LTV / 10000) - current borrowed amount
        uint256 targetBorrow = collateralValueInUSDC * targetLTV / 10000;
        uint256 additionalBorrow = targetBorrow > currentBorrowed ? 
                                 targetBorrow - currentBorrowed : 0;
        
        if (additionalBorrow > 0) {
            // Borrow more USDC from Compound III
            IComet(compoundComet).borrow(additionalBorrow);
            
            // Swap USDC for more cbBTC using Uniswap V3
            IERC20(usdcToken).approve(uniswapRouter, additionalBorrow);
            
            // Calculate minimum cbBTC expected (accounting for slippage)
            // Formula: (USDC amount / cbBTC price) * (10000 - slippage) / 10000
            uint256 expectedCbBTC = additionalBorrow * 1e18 / cbBTCPrice;
            uint256 minCbBTC = expectedCbBTC * (10000 - slippageTolerance) / 10000;
            
            // Execute the swap
            uint256 receivedCbBTC = IUniswapRouter(uniswapRouter).exactInputSingle(
                usdcToken,
                cbBTCToken,
                uniswapFeeTier,
                address(this),
                additionalBorrow,
                minCbBTC,
                0 // No price limit
            );
            
            // Supply new cbBTC as additional collateral to Compound III
            IERC20(cbBTCToken).approve(compoundComet, receivedCbBTC);
            IComet(compoundComet).supplyTo(btfdVault, cbBTCToken, receivedCbBTC);
            
            // Emit event with details of the leverage operation
            emit PositionLeveraged(receivedCbBTC, additionalBorrow, getCurrentLTV());
        }
    }
    
    //----------------------------------------------------------------
    // WITHDRAWAL AND DELEVERAGE FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Prepare for user exit by unwinding portion of leverage
     * @param sharePercentage Percentage of total to exit (in basis points)
     * @return cbBTCAmount Amount of cbBTC released for exit
     * @dev This function is called by the BTFD vault when a user withdraws
     * Workflow:
     * 1. Calculate portion of collateral and debt to unwind based on share percentage
     * 2. Withdraw some cbBTC from Compound III
     * 3. Swap part of the cbBTC for USDC to repay debt
     * 4. Repay portion of the USDC debt
     * 5. Return remaining cbBTC to vault for the user
     * 6. Update NAV to reflect the new position value
     */
    function prepareExit(uint256 sharePercentage) external nonReentrant returns (uint256 cbBTCAmount) {
        // Only vault can call this
        require(msg.sender == btfdVault, "Only vault can call");
        require(sharePercentage > 0 && sharePercentage <= 10000, "Invalid percentage");
        
        // Get current position
        uint256 totalCollateral = IComet(compoundComet).collateralBalanceOf(btfdVault, cbBTCToken);
        uint256 totalBorrowed = IComet(compoundComet).borrowBalanceOf(btfdVault);
        
        // Calculate proportional amounts to unwind
        // Example: If user has 25% of shares, unwind 25% of collateral and debt
        uint256 collateralToWithdraw = totalCollateral * sharePercentage / 10000;
        uint256 debtToRepay = totalBorrowed * sharePercentage / 10000;
        
        // If there's no position to unwind
        if (totalCollateral == 0 || totalBorrowed == 0) {
            return 0;
        }
        
        // First, calculate how much cbBTC to swap to get enough USDC for debt repayment
        uint256 cbBTCToSwap = _calculateCbBTCToSwapForUSDC(debtToRepay);
        
        // Make sure we don't try to withdraw more than the user's portion
        cbBTCToSwap = cbBTCToSwap > collateralToWithdraw ? collateralToWithdraw : cbBTCToSwap;
        
        if (cbBTCToSwap > 0) {
            // Withdraw cbBTC from Compound III to this contract
            IComet(compoundComet).withdrawTo(address(this), cbBTCToken, cbBTCToSwap);
            
            // Swap cbBTC for USDC to repay debt
            IERC20(cbBTCToken).approve(uniswapRouter, cbBTCToSwap);
            uint256 minUSDC = debtToRepay * (10000 - slippageTolerance) / 10000; // Account for slippage
            
            // Execute the swap
            uint256 receivedUSDC = IUniswapRouter(uniswapRouter).exactInputSingle(
                cbBTCToken,
                usdcToken,
                uniswapFeeTier,
                address(this),
                cbBTCToSwap,
                minUSDC,
                0 // No price limit
            );
            
            // Repay debt to Compound III
            IERC20(usdcToken).approve(compoundComet, receivedUSDC);
            IComet(compoundComet).supply(usdcToken, receivedUSDC);
            
            // Reduce remaining collateral to withdraw by the amount already swapped
            collateralToWithdraw = collateralToWithdraw > cbBTCToSwap ? 
                                   collateralToWithdraw - cbBTCToSwap : 0;
        }
        
        // Withdraw remaining collateral directly to the vault
        if (collateralToWithdraw > 0) {
            IComet(compoundComet).withdrawTo(btfdVault, cbBTCToken, collateralToWithdraw);
            cbBTCAmount = collateralToWithdraw;
        }
        
        // Update NAV to reflect the new position value
        INAVOracle(navOracle).triggerUpdate();
        
        emit ExitPrepared(sharePercentage, cbBTCAmount);
        
        return cbBTCAmount;
    }
    
    /**
     * @notice Calculate how much cbBTC to swap to get a target amount of USDC
     * @param usdcAmount Target USDC amount
     * @return Amount of cbBTC to swap
     * @dev Includes a buffer to account for slippage and price fluctuations
     * Formula: (USDC amount * (10000 + buffer) / 10000) * 1e18 / cbBTC price
     */
    function _calculateCbBTCToSwapForUSDC(uint256 usdcAmount) internal view returns (uint256) {
        // Get price of cbBTC in USDC from the oracle
        uint256 cbBTCPrice = INAVOracle(navOracle).getCbBTCPrice();
        
        // Add a buffer for slippage and fees (double the standard slippage tolerance)
        uint256 buffer = slippageTolerance * 2; // Double the slippage tolerance for safety
        
        // Calculate cbBTC amount needed with buffer
        return usdcAmount * (10000 + buffer) / 10000 * 1e18 / cbBTCPrice;
    }
    
    /**
     * @notice Reduce leverage by selling collateral to repay debt
     * @dev Internal function used when LTV exceeds the maximum target
     * Workflow:
     * 1. Calculate USDC debt to repay to reach target LTV
     * 2. Withdraw necessary cbBTC from Compound III
     * 3. Swap cbBTC for USDC
     * 4. Repay portion of USDC debt to reduce LTV
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
        
        // Calculate collateral value in USDC
        uint256 collateralValueInUSDC = collateralValue * cbBTCPrice / 1e18;
        
        // Calculate how much debt to repay to reach target LTV
        // Formula: current borrowed - (collateral value * target LTV / 10000)
        uint256 targetBorrow = collateralValueInUSDC * targetLTV / 10000;
        uint256 amountToRepay = currentBorrowed > targetBorrow ? 
                              currentBorrowed - targetBorrow : 0;
        
        if (amountToRepay > 0) {
            // Calculate cbBTC to sell to get the required USDC
            uint256 cbBTCToSell = _calculateCbBTCToSwapForUSDC(amountToRepay);
            
            // Withdraw cbBTC from Compound III
            IComet(compoundComet).withdrawTo(address(this), cbBTCToken, cbBTCToSell);
            
            // Swap cbBTC for USDC
            IERC20(cbBTCToken).approve(uniswapRouter, cbBTCToSell);
            uint256 minUSDC = amountToRepay * (10000 - slippageTolerance) / 10000;
            
            // Execute the swap
            uint256 receivedUSDC = IUniswapRouter(uniswapRouter).exactInputSingle(
                cbBTCToken,
                usdcToken,
                uniswapFeeTier,
                address(this),
                cbBTCToSell,
                minUSDC,
                0 // No price limit
            );
            
            // Repay debt to Compound III
            IERC20(usdcToken).approve(compoundComet, receivedUSDC);
            IComet(compoundComet).supply(usdcToken, receivedUSDC);
            
            emit PositionDeleveraged(receivedUSDC, cbBTCToSell, getCurrentLTV());
        }
    }
    
    //----------------------------------------------------------------
    // EMERGENCY AND MANAGEMENT FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Manual rebalance function for emergency situations
     * @dev Can be called by vault or owner to adjust the position's LTV
     * Not used in normal operations, but available for risk management
     */
    function rebalance() external {
        require(msg.sender == btfdVault || msg.sender == owner(), "Unauthorized");
        
        uint256 oldLTV = getCurrentLTV();
        _applyEntryLeverage();
        uint256 newLTV = getCurrentLTV();
        
        emit LTVAdjusted(oldLTV, newLTV);
    }
    
    /**
     * @notice Emergency function to force deleverage in extreme market conditions
     * @param targetLTVBps Target LTV in basis points to reduce to
     * @dev Allows owner to quickly reduce leverage during market volatility
     * Workflow:
     * 1. Temporarily set a lower target LTV
     * 2. Execute deleveraging to reach that target
     * 3. Restore original target LTV
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
    
    /**
     * @notice Emergency function to withdraw all tokens in case of critical issues
     * @dev Allows owner to rescue any tokens held by this contract
     * Transfers them back to the BTFD vault
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
    
    //----------------------------------------------------------------
    // PARAMETER CONFIGURATION FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Set target LTV ratio
     * @param _targetLTV New target LTV in basis points
     * @dev The target LTV should be less than the maximum LTV
     * This is the leverage level the strategy aims to maintain
     */
    function setTargetLTV(uint256 _targetLTV) external onlyOwner {
        require(_targetLTV > 0 && _targetLTV < maxLTV, "Invalid target LTV");
        targetLTV = _targetLTV;
    }
    
    /**
     * @notice Set maximum LTV before deleveraging
     * @param _maxLTV New max LTV in basis points
     * @dev This is the upper limit before the position is considered too risky
     * and needs to be deleveraged back to the target
     */
    function setMaxLTV(uint256 _maxLTV) external onlyOwner {
        require(_maxLTV > targetLTV, "Max LTV must be higher than target");
        maxLTV = _maxLTV;
    }
    
    /**
     * @notice Set slippage tolerance for swaps
     * @param _slippageTolerance New slippage tolerance in basis points
     * @dev This affects the minimum output amount accepted for swaps
     * Higher values allow more slippage but reduce the chance of failed swaps
     */
    function setSlippageTolerance(uint256 _slippageTolerance) external onlyOwner {
        require(_slippageTolerance < 1000, "Slippage too high"); // Max 10%
        slippageTolerance = _slippageTolerance;
    }
    
    /**
     * @notice Set Uniswap fee tier
     * @param _uniswapFeeTier New fee tier
     * @dev Fee in hundredths of a bip (e.g., 3000 = 0.3%)
     * Different fee tiers provide different levels of liquidity
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
     * @dev Only updates addresses that are non-zero
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
     * @dev Only updates addresses that are non-zero
     */
    function updateTokenAddresses(
        address _cbBTCToken,
        address _usdcToken
    ) external onlyOwner {
        if (_cbBTCToken != address(0)) cbBTCToken = _cbBTCToken;
        if (_usdcToken != address(0)) usdcToken = _usdcToken;
    }
}