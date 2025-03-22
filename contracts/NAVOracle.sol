// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IPriceOracle {
    function getCbBTCPrice() external view returns (uint256);
}

interface ILeverageManager {
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount);
}

/**
 * @title NAVOracle
 * @notice Calculates and tracks Net Asset Value for the BTFD vault's leveraged position on Base
 * @dev NAV calculations account for varying entry prices and profit/loss calculations
 * for each user based on when they entered the position
 */
contract NAVOracle is Ownable {
    // BTFD Vault (ERC-4626 compliant)
    address public btfdVault;
    // Leverage manager contract
    address public leverageManager;
    // Price oracle
    address public priceOracle;
    
    // Token addresses
    address public cbBTCToken;
    address public usdcToken;
    
    // NAV data structure
    struct NAVData {
        uint256 timestamp;
        uint256 totalAssetValueInUSDC;
        uint256 totalDebtInUSDC;
        uint256 netAssetValue;
        uint256 sharesOutstanding;
        uint256 navPerShare;
    }
    
    // Latest NAV calculation
    NAVData public latestNAV;
    
    // Minimum time between updates (prevents too frequent updates)
    uint256 public minUpdateInterval;
    
    // Threshold for price movement to trigger update (in basis points)
    uint256 public priceUpdateThreshold;
    
    // Last recorded cbBTC price
    uint256 public lastCbBTCPrice;
    
    event NAVUpdated(
        uint256 timestamp,
        uint256 totalAssetValue,
        uint256 totalDebt,
        uint256 netValue,
        uint256 navPerShare
    );
    
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
    
    /**
     * @notice Calculate full NAV including all assets and debts
     * @return Latest NAV data
     */
    function calculateNAV() public returns (NAVData memory) {
        // Check if update is needed based on time or price movement
        if (!shouldUpdateNAV()) {
            return latestNAV;
        }
        
        // 1. Get cbBTC price from oracle
        uint256 cbBTCPrice = IPriceOracle(priceOracle).getCbBTCPrice();
        lastCbBTCPrice = cbBTCPrice;
        
        // 2. Get cbBTC in the vault
        uint256 vaultCbBTC = IERC20(cbBTCToken).balanceOf(btfdVault);
        
        // 3. Get cbBTC supplied to Compound and borrowed USDC
        (uint256 suppliedCbBTC, uint256 borrowedUSDC) = ILeverageManager(leverageManager).getPositionDetails();
        
        // 4. Calculate total asset value in USDC
        uint256 totalAssetValue = (vaultCbBTC + suppliedCbBTC) * cbBTCPrice / 1e18;
        
        // 5. Calculate net value
        uint256 netValue = totalAssetValue > borrowedUSDC ? totalAssetValue - borrowedUSDC : 0;
        
        // 6. Get total shares from ERC-4626 vault
        uint256 sharesOutstanding = IERC20(btfdVault).totalSupply();
        
        // 7. Calculate NAV per share
        uint256 navPerShare = sharesOutstanding > 0 ? netValue * 1e18 / sharesOutstanding : 0;
        
        // 8. Update latest NAV
        latestNAV = NAVData({
            timestamp: block.timestamp,
            totalAssetValueInUSDC: totalAssetValue,
            totalDebtInUSDC: borrowedUSDC,
            netAssetValue: netValue,
            sharesOutstanding: sharesOutstanding,
            navPerShare: navPerShare
        });
        
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
     * @notice Determine if NAV needs updating based on time or price movement
     * @return True if update is needed
     */
    function shouldUpdateNAV() public view returns (bool) {
        // Always update if this is first calculation
        if (latestNAV.timestamp == 0) {
            return true;
        }
        
        // Update if sufficient time has passed
        if (block.timestamp >= latestNAV.timestamp + minUpdateInterval) {
            return true;
        }
        
        // Update if price has moved significantly
        uint256 currentPrice = IPriceOracle(priceOracle).getCbBTCPrice();
        uint256 priceDifference;
        
        if (currentPrice > lastCbBTCPrice) {
            priceDifference = ((currentPrice - lastCbBTCPrice) * 10000) / lastCbBTCPrice;
        } else {
            priceDifference = ((lastCbBTCPrice - currentPrice) * 10000) / lastCbBTCPrice;
        }
        
        if (priceDifference >= priceUpdateThreshold) {
            return true;
        }
        
        return false;
    }
    
    /**
     * @notice Get current asset conversion rate from cbBTC to shares
     * @param cbBTCAmount Amount of cbBTC
     * @return Estimated shares for the given cbBTC amount
     */
    function previewDeposit(uint256 cbBTCAmount) external view returns (uint256) {
        return IERC4626(btfdVault).previewDeposit(cbBTCAmount);
    }
    
    /**
     * @notice Get current share conversion rate to cbBTC
     * @param shares Number of shares
     * @return Estimated cbBTC amount for the given shares
     */
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return IERC4626(btfdVault).previewRedeem(shares);
    }
    
    /**
     * @notice Get the current NAV per share without triggering an update
     * @return Current NAV per share value
     */
    function getCurrentNAVPerShare() external view returns (uint256) {
        if (latestNAV.timestamp == 0 || latestNAV.sharesOutstanding == 0) {
            // If no NAV calculation has been done yet, calculate a fresh one
            uint256 cbBTCPrice = IPriceOracle(priceOracle).getCbBTCPrice();
            uint256 vaultCbBTC = IERC20(cbBTCToken).balanceOf(btfdVault);
            (uint256 suppliedCbBTC, uint256 borrowedUSDC) = ILeverageManager(leverageManager).getPositionDetails();
            
            uint256 totalAssetValue = (vaultCbBTC + suppliedCbBTC) * cbBTCPrice / 1e18;
            uint256 netValue = totalAssetValue > borrowedUSDC ? totalAssetValue - borrowedUSDC : 0;
            uint256 sharesOutstanding = IERC20(btfdVault).totalSupply();
            
            return sharesOutstanding > 0 ? netValue * 1e18 / sharesOutstanding : 0;
        }
        
        return latestNAV.navPerShare;
    }
    
    /**
     * @notice Get the current cbBTC price
     * @return Current cbBTC price in USDC (18 decimals)
     */
    function getCbBTCPrice() external view returns (uint256) {
        return IPriceOracle(priceOracle).getCbBTCPrice();
    }
    
    /**
     * @notice Force an NAV update
     * @dev Only callable by authorized addresses
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
    
    /**
     * @notice Set minimum update interval
     * @param interval New interval in seconds
     */
    function setMinUpdateInterval(uint256 interval) external onlyOwner {
        minUpdateInterval = interval;
    }
    
    /**
     * @notice Set price update threshold
     * @param threshold New threshold in basis points
     */
    function setPriceUpdateThreshold(uint256 threshold) external onlyOwner {
        priceUpdateThreshold = threshold;
    }
    
    /**
     * @notice Update contract addresses
     * @param _btfdVault New vault address
     * @param _leverageManager New leverage manager address
     * @param _priceOracle New price oracle address
     */
    function updateAddresses(
        address _btfdVault,
        address _leverageManager,
        address _priceOracle
    ) external onlyOwner {
        btfdVault = _btfdVault;
        leverageManager = _leverageManager;
        priceOracle = _priceOracle;
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
}