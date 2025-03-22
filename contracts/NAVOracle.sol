// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @dev Interface for the price oracle that provides cbBTC/USDC price data
 */
interface IPriceOracle {
    /**
     * @notice Gets the current price of cbBTC in USDC
     * @return Current price with 18 decimals of precision
     */
    function getCbBTCPrice() external view returns (uint256);
}

/**
 * @dev Interface for the LeverageManager that manages the Compound III position
 */
interface ILeverageManager {
    /**
     * @notice Gets the current collateral and debt balances
     * @return suppliedAmount Amount of cbBTC supplied as collateral
     * @return borrowedAmount Amount of USDC borrowed
     */
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount);
}

/**
 * @title NAVOracle
 * @notice Calculates and tracks Net Asset Value for the BTFD vault's leveraged position
 * 
 * This contract serves multiple critical functions:
 * 
 * 1. Accurate NAV Calculation: Computes the true Net Asset Value of the leveraged position
 *    by accounting for assets (cbBTC in vault + collateral in Compound) and liabilities (borrowed USDC)
 * 
 * 2. Share Value Determination: Calculates the NAV per share, which is essential for
 *    determining fair entry and exit prices for users of the BTFD vault
 * 
 * 3. Position Monitoring: Provides up-to-date information about the overall health and
 *    performance of the leveraged strategy
 * 
 * 4. Efficient Updates: Implements an optimized update strategy that balances
 *    accuracy with gas efficiency through time and price-based update triggers
 * 
 * The NAV calculation is a critical component for the entire system as it ensures
 * users receive their fair share of assets when entering or exiting the vault.
 */
contract NAVOracle is Ownable {
    //----------------------------------------------------------------
    // STATE VARIABLES
    //----------------------------------------------------------------
    
    /**
     * @notice Address of the BTFD vault (ERC-4626 compliant)
     * @dev This is the main vault contract that holds user shares
     */
    address public btfdVault;
    
    /**
     * @notice Address of the LeverageManager that handles Compound III interactions
     * @dev Used to query current collateral and debt positions
     */
    address public leverageManager;
    
    /**
     * @notice Address of the price oracle for cbBTC/USDC
     * @dev Provides current market prices for NAV calculations
     */
    address public priceOracle;
    
    /**
     * @notice Address of the cbBTC token (Bitcoin on Base)
     * @dev This is the asset being tracked in the NAV calculations
     */
    address public cbBTCToken;
    
    /**
     * @notice Address of the USDC token
     * @dev Used for debt denomination and NAV value calculations
     */
    address public usdcToken;
    
    /**
     * @notice Data structure for storing NAV calculation results
     * @param timestamp When this NAV calculation was performed
     * @param totalAssetValueInUSDC Total value of all assets (in USDC terms)
     * @param totalDebtInUSDC Total borrowed amount (in USDC)
     * @param netAssetValue Net value after deducting debt (assets - debt)
     * @param sharesOutstanding Total shares issued by the vault
     * @param navPerShare NAV per share (used for deposits/withdrawals)
     */
    struct NAVData {
        uint256 timestamp;            // When this calculation was performed
        uint256 totalAssetValueInUSDC; // Total asset value in USDC terms
        uint256 totalDebtInUSDC;      // Total debt in USDC
        uint256 netAssetValue;        // Net value (assets - debt)
        uint256 sharesOutstanding;    // Total shares issued
        uint256 navPerShare;          // Value per share
    }
    
    /**
     * @notice Most recent NAV calculation result
     * @dev Updated by calculateNAV() and accessed by various getter functions
     */
    NAVData public latestNAV;
    
    /**
     * @notice Minimum time between forced NAV updates
     * @dev In seconds - prevents excessive updates to save gas
     */
    uint256 public minUpdateInterval;
    
    /**
     * @notice Price movement threshold to trigger an update
     * @dev In basis points (e.g., 100 = 1%) - triggers update on significant price changes
     */
    uint256 public priceUpdateThreshold;
    
    /**
     * @notice Last recorded cbBTC price from the oracle
     * @dev Used to detect significant price movements
     */
    uint256 public lastCbBTCPrice;
    
    /**
     * @notice Emitted when a new NAV calculation is performed
     * @param timestamp When the calculation was performed
     * @param totalAssetValue Total value of all assets (in USDC)
     * @param totalDebt Total debt (in USDC)
     * @param netValue Net value after deducting debt
     * @param navPerShare The calculated NAV per share
     */
    event NAVUpdated(
        uint256 timestamp,
        uint256 totalAssetValue,
        uint256 totalDebt,
        uint256 netValue,
        uint256 navPerShare
    );
    
    //----------------------------------------------------------------
    // CONSTRUCTOR
    //----------------------------------------------------------------
    
    /**
     * @notice Initialize the NAV Oracle with required addresses
     * @param _btfdVault Address of the BTFD vault
     * @param _leverageManager Address of the leverage manager
     * @param _priceOracle Address of the price oracle for cbBTC
     * @param _cbBTCToken Address of the cbBTC token
     * @param _usdcToken Address of the USDC token
     * @dev Sets default parameters:
     *   - minUpdateInterval: 1 hour (prevents excessive updates)
     *   - priceUpdateThreshold: 1% (triggers update on significant price movement)
     */
    constructor(
        address _btfdVault,
        address _leverageManager,
        address _priceOracle,
        address _cbBTCToken,
        address _usdcToken
    ) Ownable(msg.sender) {
        btfdVault = _btfdVault;
        leverageManager = _leverageManager;
        priceOracle = _priceOracle;
        cbBTCToken = _cbBTCToken;
        usdcToken = _usdcToken;
        
        minUpdateInterval = 1 hours;
        priceUpdateThreshold = 100; // 1% in basis points
    }
    
    //----------------------------------------------------------------
    // NAV CALCULATION FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Calculate complete NAV for the entire position
     * @return Latest NAV data structure with calculated values
     * @dev This is the core function that computes the NAV using the following steps:
     * 
     * 1. Check if update is needed (based on time or price movement)
     * 2. Get current cbBTC price from oracle
     * 3. Calculate value of cbBTC held directly in the vault
     * 4. Get cbBTC collateral and USDC debt from Compound III
     * 5. Calculate total asset value (vault cbBTC + supplied cbBTC) in USDC terms
     * 6. Calculate net value (total assets - debt)
     * 7. Get current outstanding shares from the vault
     * 8. Calculate NAV per share (net value / shares outstanding)
     * 9. Store results and emit event
     * 
     * The calculation includes all assets and liabilities to provide an accurate
     * representation of the position's value.
     */
    function calculateNAV() public returns (NAVData memory) {
        // Check if update is needed based on time or price movement
        if (!shouldUpdateNAV()) {
            return latestNAV;
        }
        
        // 1. Get cbBTC price from oracle
        uint256 cbBTCPrice = IPriceOracle(priceOracle).getCbBTCPrice();
        lastCbBTCPrice = cbBTCPrice;
        
        // 2. Get cbBTC held directly in the vault
        uint256 vaultCbBTC = IERC20(cbBTCToken).balanceOf(btfdVault);
        
        // 3. Get cbBTC supplied to Compound and borrowed USDC
        (uint256 suppliedCbBTC, uint256 borrowedUSDC) = ILeverageManager(leverageManager).getPositionDetails();
        
        // 4. Calculate total asset value in USDC
        // Formula: (vault cbBTC + supplied cbBTC) * cbBTC price / 1e18
        uint256 totalAssetValue = (vaultCbBTC + suppliedCbBTC) * cbBTCPrice / 1e18;
        
        // 5. Calculate net value (assets minus debt)
        uint256 netValue = totalAssetValue > borrowedUSDC ? totalAssetValue - borrowedUSDC : 0;
        
        // 6. Get total shares from the vault
        uint256 sharesOutstanding = IERC20(btfdVault).totalSupply();
        
        // 7. Calculate NAV per share
        // Formula: (net value * 1e18) / shares outstanding
        // The 1e18 factor provides precision for the per-share value
        uint256 navPerShare = sharesOutstanding > 0 ? netValue * 1e18 / sharesOutstanding : 0;
        
        // 8. Update latest NAV data structure
        latestNAV = NAVData({
            timestamp: block.timestamp,
            totalAssetValueInUSDC: totalAssetValue,
            totalDebtInUSDC: borrowedUSDC,
            netAssetValue: netValue,
            sharesOutstanding: sharesOutstanding,
            navPerShare: navPerShare
        });
        
        // 9. Emit event with the new NAV details
        emit NAVUpdated(
            block.timestamp,
            totalAssetValue,
            borrowedUSDC,
            netValue,
            navPerShare
        );
        
        return latestNAV;
    }
    
    /**
     * @notice Determines if NAV needs updating based on time or price movement
     * @return True if update is needed, false otherwise
     * @dev Update is triggered if any of these conditions are met:
     *   1. This is the first NAV calculation (timestamp is 0)
     *   2. Minimum time interval has passed since last update
     *   3. cbBTC price has moved by more than the update threshold
     * 
     * This optimization prevents excessive updates while ensuring
     * the NAV remains accurate during significant market movements.
     */
    function shouldUpdateNAV() public view returns (bool) {
        // Always update if this is first calculation
        if (latestNAV.timestamp == 0) {
            return true;
        }
        
        // Update if sufficient time has passed since last calculation
        if (block.timestamp >= latestNAV.timestamp + minUpdateInterval) {
            return true;
        }
        
        // Update if price has moved significantly
        uint256 currentPrice = IPriceOracle(priceOracle).getCbBTCPrice();
        uint256 priceDifference;
        
        // Calculate percentage price difference in basis points
        if (currentPrice > lastCbBTCPrice) {
            priceDifference = ((currentPrice - lastCbBTCPrice) * 10000) / lastCbBTCPrice;
        } else {
            priceDifference = ((lastCbBTCPrice - currentPrice) * 10000) / lastCbBTCPrice;
        }
        
        // Update if price movement exceeds threshold
        if (priceDifference >= priceUpdateThreshold) {
            return true;
        }
        
        // No update needed
        return false;
    }
    
    //----------------------------------------------------------------
    // VIEW & EXTERNAL FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Get current asset conversion rate from cbBTC to shares
     * @param cbBTCAmount Amount of cbBTC to convert
     * @return Estimated shares for the given cbBTC amount
     * @dev Delegates to the vault's previewDeposit function for accurate conversion
     * This reflects the current rate at which assets are converted to shares
     */
    function previewDeposit(uint256 cbBTCAmount) external view returns (uint256) {
        return IERC4626(btfdVault).previewDeposit(cbBTCAmount);
    }
    
    /**
     * @notice Get current share conversion rate to cbBTC
     * @param shares Number of shares to convert
     * @return Estimated cbBTC amount for the given shares
     * @dev Delegates to the vault's previewRedeem function for accurate conversion
     * This reflects the current rate at which shares are converted back to assets
     */
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return IERC4626(btfdVault).previewRedeem(shares);
    }
    
    /**
     * @notice Get the current NAV per share without forcing an update
     * @return Current NAV per share value (with 18 decimals precision)
     * @dev If no NAV calculation exists yet, performs a fresh calculation
     * Otherwise returns the latest calculated value
     */
    function getCurrentNAVPerShare() external view returns (uint256) {
        if (latestNAV.timestamp == 0 || latestNAV.sharesOutstanding == 0) {
            // If no NAV calculation has been done yet, calculate a fresh one
            uint256 cbBTCPrice = IPriceOracle(priceOracle).getCbBTCPrice();
            uint256 vaultCbBTC = IERC20(cbBTCToken).balanceOf(btfdVault);
            (uint256 suppliedCbBTC, uint256 borrowedUSDC) = ILeverageManager(leverageManager).getPositionDetails();
            
            // Calculate total asset value and net value
            uint256 totalAssetValue = (vaultCbBTC + suppliedCbBTC) * cbBTCPrice / 1e18;
            uint256 netValue = totalAssetValue > borrowedUSDC ? totalAssetValue - borrowedUSDC : 0;
            uint256 sharesOutstanding = IERC20(btfdVault).totalSupply();
            
            // Calculate and return NAV per share
            return sharesOutstanding > 0 ? netValue * 1e18 / sharesOutstanding : 0;
        }
        
        // Return the previously calculated NAV per share
        return latestNAV.navPerShare;
    }
    
    /**
     * @notice Get the current price of cbBTC in USDC
     * @return Current cbBTC price with 18 decimals precision
     * @dev This is a convenience function that delegates to the price oracle
     */
    function getCbBTCPrice() external view returns (uint256) {
        return IPriceOracle(priceOracle).getCbBTCPrice();
    }
    
    /**
     * @notice Force an immediate NAV update regardless of thresholds
     * @dev Callable only by authorized contracts or owner
     * Used when actions occur that significantly impact the NAV,
     * such as deposits, withdrawals, or leverage adjustments
     */
    function triggerUpdate() external {
        require(
            msg.sender == btfdVault || 
            msg.sender == leverageManager || 
            msg.sender == owner(),
            "Unauthorized"
        );
        
        calculateNAV();
    }
    
    //----------------------------------------------------------------
    // ADMIN FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Set minimum time between NAV updates
     * @param interval New interval in seconds
     * @dev Lower values increase accuracy but also gas costs
     * Higher values save gas but may lead to temporary NAV inaccuracies
     */
    function setMinUpdateInterval(uint256 interval) external onlyOwner {
        minUpdateInterval = interval;
    }
    
    /**
     * @notice Set price movement threshold for triggering updates
     * @param threshold New threshold in basis points
     * @dev Lower values (e.g., 50 = 0.5%) make NAV more responsive to price changes
     * Higher values reduce update frequency but may delay NAV adjustments
     */
    function setPriceUpdateThreshold(uint256 threshold) external onlyOwner {
        priceUpdateThreshold = threshold;
    }
    
    /**
     * @notice Update contract addresses
     * @param _btfdVault New vault address
     * @param _leverageManager New leverage manager address
     * @param _priceOracle New price oracle address
     * @dev Only non-zero addresses will be updated
     */
    function updateAddresses(
        address _btfdVault,
        address _leverageManager,
        address _priceOracle
    ) external onlyOwner {
        if (_btfdVault != address(0)) btfdVault = _btfdVault;
        if (_leverageManager != address(0)) leverageManager = _leverageManager;
        if (_priceOracle != address(0)) priceOracle = _priceOracle;
    }
    
    /**
     * @notice Update token addresses
     * @param _cbBTCToken New cbBTC token address
     * @param _usdcToken New USDC token address
     * @dev Only non-zero addresses will be updated
     */
    function updateTokenAddresses(
        address _cbBTCToken,
        address _usdcToken
    ) external onlyOwner {
        if (_cbBTCToken != address(0)) cbBTCToken = _cbBTCToken;
        if (_usdcToken != address(0)) usdcToken = _usdcToken;
    }
}