// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceOracle {
    function getPrice() external view returns (uint256);
}

interface ILeverageManager {
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount);
}

interface IMolochDAO {
    function totalShares() external view returns (uint256);
}

/**
 * @title NAVOracle
 * @notice Calculates and tracks Net Asset Value for the DAO's leveraged position
 */
contract NAVOracle is Ownable {
    // Treasury (Gnosis Safe)
    address public treasury;
    // Leverage manager contract
    address public leverageManager;
    // Price oracle
    address public priceOracle;
    // MolochDAO
    address public molochDAO;
    
    // Token addresses
    address public fbtcToken;
    address public usdeToken;
    
    // NAV data structure
    struct NAVData {
        uint256 timestamp;
        uint256 totalAssetValueInUSDe;
        uint256 totalDebtInUSDe;
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
    
    // Last recorded FBTC price
    uint256 public lastFbtcPrice;
    
    event NAVUpdated(
        uint256 timestamp,
        uint256 totalAssetValue,
        uint256 totalDebt,
        uint256 netValue,
        uint256 navPerShare
    );
    
    constructor(
        address _treasury,
        address _leverageManager,
        address _priceOracle,
        address _molochDAO,
        address _fbtcToken,
        address _usdeToken
    ) Ownable(msg.sender) {
        treasury = _treasury;
        leverageManager = _leverageManager;
        priceOracle = _priceOracle;
        molochDAO = _molochDAO;
        fbtcToken = _fbtcToken;
        usdeToken = _usdeToken;
        
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
        
        // 1. Get FBTC price from oracle
        uint256 fbtcPrice = IPriceOracle(priceOracle).getPrice();
        lastFbtcPrice = fbtcPrice;
        
        // 2. Get total FBTC in treasury
        uint256 treasuryFBTC = IERC20(fbtcToken).balanceOf(treasury);
        
        // 3. Get FBTC supplied to Compound and borrowed USDe
        (uint256 suppliedFBTC, uint256 borrowedUSDe) = ILeverageManager(leverageManager).getPositionDetails();
        
        // 4. Calculate total asset value in USDe
        uint256 totalAssetValue = (treasuryFBTC + suppliedFBTC) * fbtcPrice / 1e18;
        
        // 5. Calculate net value
        uint256 netValue = totalAssetValue > borrowedUSDe ? totalAssetValue - borrowedUSDe : 0;
        
        // 6. Get total shares from DAO
        uint256 sharesOutstanding = IMolochDAO(molochDAO).totalShares();
        
        // 7. Calculate NAV per share
        uint256 navPerShare = sharesOutstanding > 0 ? netValue * 1e18 / sharesOutstanding : 0;
        
        // 8. Update latest NAV
        latestNAV = NAVData({
            timestamp: block.timestamp,
            totalAssetValueInUSDe: totalAssetValue,
            totalDebtInUSDe: borrowedUSDe,
            netAssetValue: netValue,
            sharesOutstanding: sharesOutstanding,
            navPerShare: navPerShare
        });
        
        emit NAVUpdated(
            block.timestamp,
            totalAssetValue,
            borrowedUSDe,
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
        uint256 currentPrice = IPriceOracle(priceOracle).getPrice();
        uint256 priceDifference;
        
        if (currentPrice > lastFbtcPrice) {
            priceDifference = ((currentPrice - lastFbtcPrice) * 10000) / lastFbtcPrice;
        } else {
            priceDifference = ((lastFbtcPrice - currentPrice) * 10000) / lastFbtcPrice;
        }
        
        if (priceDifference >= priceUpdateThreshold) {
            return true;
        }
        
        return false;
    }
    
    /**
     * @notice Calculate shares to mint for new deposit based on current NAV
     * @param fbtcAmount Amount of FBTC being deposited
     * @return Shares to mint
     */
    function calculateSharesForDeposit(uint256 fbtcAmount) external view returns (uint256) {
        if (latestNAV.navPerShare == 0) {
            // Initial case - 1:1 ratio between FBTC value and shares
            uint256 fbtcValue = fbtcAmount * IPriceOracle(priceOracle).getPrice() / 1e18;
            return fbtcValue;
        }
        
        // Calculate FBTC value
        uint256 fbtcValue = fbtcAmount * IPriceOracle(priceOracle).getPrice() / 1e18;
        
        // Calculate shares based on current NAV
        return fbtcValue * 1e18 / latestNAV.navPerShare;
    }
    
    /**
     * @notice Calculate FBTC to return for shares being redeemed
     * @param shares Number of shares being redeemed
     * @return FBTC amount to return
     */
    function calculateFBTCForShares(uint256 shares) external view returns (uint256) {
        if (latestNAV.navPerShare == 0 || latestNAV.sharesOutstanding == 0) {
            return 0;
        }
        
        // Calculate USDe value of shares
        uint256 usdeValue = shares * latestNAV.navPerShare / 1e18;
        
        // Convert to FBTC
        uint256 fbtcPrice = IPriceOracle(priceOracle).getPrice();
        return usdeValue * 1e18 / fbtcPrice;
    }
    
    /**
     * @notice Force an NAV update
     * @dev Only callable by authorized addresses
     */
    function triggerUpdate() external {
        require(
            msg.sender == treasury || 
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
     * @param _treasury New treasury address
     * @param _leverageManager New leverage manager address
     * @param _priceOracle New price oracle address
     * @param _molochDAO New MolochDAO address
     */
    function updateAddresses(
        address _treasury,
        address _leverageManager,
        address _priceOracle,
        address _molochDAO
    ) external onlyOwner {
        treasury = _treasury;
        leverageManager = _leverageManager;
        priceOracle = _priceOracle;
        molochDAO = _molochDAO;
    }
}