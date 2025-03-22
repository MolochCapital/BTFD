// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BTFD - Cooperative Leverage Trading Vault
 * @notice ERC-4626 compliant vault implementing a cooperative "Buy The Dip" strategy
 * 
 * This system enables:
 * 1. Cooperative leveraged positions where later entrants at lower prices support earlier positions
 * 2. Strike price based entry system for automatic DCA at user-specified price points
 * 3. Individual profit tracking with performance fees based on personal entry price
 * 4. Performance fees remain in the vault to benefit remaining participants
 * 5. Independent exit mechanism that maintains position integrity for remaining users
 */

interface ILeverageManager {
    function onDeposit(uint256 amount) external;
    function prepareExit(uint256 sharePercentage) external returns (uint256 cbBTCAmount);
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount);
}

interface IPriceOracle {
    function getCbBTCPrice() external view returns (uint256);
}

interface IStrikePriceHook {
    function checkAndTriggerStrikes() external;
}

contract BTFD is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //----------------------------------------------------------------
    // STATE VARIABLES
    //----------------------------------------------------------------
    
    // Integrated contracts
    ILeverageManager public leverageManager;
    IPriceOracle public priceOracle;
    IStrikePriceHook public strikeHook;
    
    // Token addresses
    address public cbBTCToken; // Underlying asset (cbBTC)
    address public usdcToken;  // Stablecoin for trading (USDC)
    
    // Fee configuration
    /**
     * @notice Performance fee paid by exiting users on their profits
     * @dev Fee stays in the vault for the benefit of remaining participants
     */
    uint256 public performanceFee; // In basis points (e.g., 500 = 5%)
    
    // Entry tracking for performance fees
    mapping(address => uint256) public userEntryPrices; // cbBTC price when user entered
    mapping(address => uint256) public userEntryShares; // Shares at entry (for tracking)
    
    // Strike price system
    mapping(address => uint256) public strikePoints; // User strike prices (USDC per cbBTC)
    mapping(address => uint256) public pendingDeposits; // USDC deposited and waiting for strike
    
    // Vault configuration
    uint256 public maxSlippage; // Maximum allowed slippage for swaps (basis points)
    bool public depositsPaused;
    bool public withdrawalsPaused;
    
    // Events
    event StrikePriceSet(address indexed user, uint256 price);
    event PendingDepositAdded(address indexed user, uint256 usdcAmount);
    event StrikeTriggered(address indexed user, uint256 usdcAmount, uint256 cbBTCAmount, uint256 shares);
    event PerformanceFeePaid(address indexed user, uint256 cbBTCAmount);
    event WithdrawalProcessed(address indexed user, uint256 shares, uint256 cbBTCAmount);
    event NAVIncreasedFromFees(uint256 feeAmount, uint256 newNavPerShare);
    
    //----------------------------------------------------------------
    // CONSTRUCTOR & SETUP
    //----------------------------------------------------------------
    
    /**
     * @notice Initialize the vault
     * @param _cbBTCToken cbBTC token address (vault underlying asset)
     * @param _usdcToken USDC token address (for pending deposits)
     * @param _leverageManager Address of the leverage manager contract
     * @param _priceOracle Address of the price oracle
     * @param _strikeHook Address of the strike price hook
     * @param _name ERC20 name for vault shares
     * @param _symbol ERC20 symbol for vault shares
     */
    constructor(
        address _cbBTCToken,
        address _usdcToken,
        address _leverageManager,
        address _priceOracle, 
        address _strikeHook,
        string memory _name,
        string memory _symbol
    ) ERC4626(IERC20(_cbBTCToken)) ERC20(_name, _symbol) Ownable(msg.sender) {
        cbBTCToken = _cbBTCToken;
        usdcToken = _usdcToken;
        leverageManager = ILeverageManager(_leverageManager);
        priceOracle = IPriceOracle(_priceOracle);
        strikeHook = IStrikePriceHook(_strikeHook);
        
        performanceFee = 500; // 5% by default
        maxSlippage = 300; // 3% by default
    }
    
    //----------------------------------------------------------------
    // ERC4626 OVERRIDES
    //----------------------------------------------------------------
    
    /**
     * @notice Returns the total assets managed by the vault
     * @return Total value of assets in the vault (including those deployed in strategy)
     */
    function totalAssets() public view override returns (uint256) {
        (uint256 suppliedAmount, uint256 borrowedAmount) = leverageManager.getPositionDetails();
        
        // Get value of cbBTC in USDC
        uint256 cbBTCPrice = priceOracle.getCbBTCPrice();
        
        // Add vault's internal balance
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        
        // Calculate leveraged position value 
        uint256 leveragedAssets = suppliedAmount > 0 ? suppliedAmount - (borrowedAmount / cbBTCPrice) : 0;
        
        return vaultBalance + leveragedAssets;
    }
    
    /**
     * @notice Deposit cbBTC to the vault
     * @dev Overridden to add entry price tracking for performance fees
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        require(!depositsPaused, "Deposits are paused");
        require(assets > 0, "Cannot deposit 0 assets");
        
        // Get current cbBTC price for entry tracking
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        
        // Calculate shares to mint
        uint256 shares = previewDeposit(assets);
        require(shares > 0, "Zero shares");
        
        // Update user's entry data
        _updateUserEntry(receiver, shares, currentPrice);
        
        // Transfer assets from sender to vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        
        // Mint shares to receiver
        _mint(receiver, shares);
        
        // Deploy to strategy
        _deployToStrategy(assets);
        
        emit Deposit(msg.sender, receiver, assets, shares);
        
        return shares;
    }
    
    /**
     * @notice Withdraw cbBTC from the vault
     * @dev Overridden to unwind leverage and calculate performance fees
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256) {
        require(!withdrawalsPaused, "Withdrawals are paused");
        require(assets > 0, "Cannot withdraw 0 assets");
        
        // Calculate shares to burn
        uint256 shares = previewWithdraw(assets);
        require(shares > 0, "Zero shares");
        
        // Check allowance if not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        
        // Calculate share percentage (in basis points)
        uint256 sharePercentage = (shares * 10000) / totalSupply();
        
        // Get current price for performance fee calculation
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        
        // Unwind leveraged position
        uint256 cbBTCReceived = _withdrawFromStrategy(sharePercentage);
        
        // Calculate and apply performance fee
        uint256 feeAmount = _calculatePerformanceFee(owner, cbBTCReceived, currentPrice);
        uint256 finalAmount = cbBTCReceived - feeAmount;
        
        // Update user's entry data
        _updateUserExitData(owner, shares);
        
        // Burn shares
        _burn(owner, shares);
        
        // Transfer assets to receiver
        IERC20(asset()).safeTransfer(receiver, finalAmount);
        
        if (feeAmount > 0 && totalSupply() > 0) {
            // Calculate new NAV per share after fee retention
            uint256 newNavPerShare = totalAssets() * 1e18 / totalSupply();
            emit NAVIncreasedFromFees(feeAmount, newNavPerShare);
        }
        
        emit Withdraw(msg.sender, receiver, owner, finalAmount, shares);
        
        return shares;
    }
    
    //----------------------------------------------------------------
    // STRIKE PRICE FUNCTIONALITY
    //----------------------------------------------------------------
    
    /**
     * @notice Set a strike price for cbBTC entry
     * @param strikePrice The price at which USDC converts to cbBTC (in USDC per cbBTC)
     */
    function setStrikePoint(uint256 strikePrice) external {
        require(strikePrice > 0, "Strike price must be greater than 0");
        strikePoints[msg.sender] = strikePrice;
        
        emit StrikePriceSet(msg.sender, strikePrice);
    }
    
    /**
     * @notice Deposit USDC to wait for cbBTC strike price
     * @param usdcAmount Amount of USDC to deposit
     */
    function depositUSDCPending(uint256 usdcAmount) external nonReentrant {
        require(!depositsPaused, "Deposits are paused");
        require(usdcAmount > 0, "Cannot deposit 0");
        require(strikePoints[msg.sender] > 0, "Set strike price first");
        
        // Transfer USDC from user to vault
        IERC20(usdcToken).safeTransferFrom(msg.sender, address(this), usdcAmount);
        
        // Record pending deposit
        pendingDeposits[msg.sender] += usdcAmount;
        
        emit PendingDepositAdded(msg.sender, usdcAmount);
        
        // Check if strike price is already hit
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        if (currentPrice <= strikePoints[msg.sender]) {
            _triggerStrike(msg.sender);
        }
    }
    
    /**
     * @notice Trigger conversion of USDC to cbBTC when strike price is hit
     * @param user Address of user whose strike price is hit
     */
    function _triggerStrike(address user) internal {
        uint256 usdcAmount = pendingDeposits[user];
        require(usdcAmount > 0, "No pending deposit");
        
        // Reset pending deposit first to prevent reentrancy
        pendingDeposits[user] = 0;
        
        // Get current price
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        
        // Calculate cbBTC amount
        uint256 cbBTCAmount = (usdcAmount * 1e18) / currentPrice;
        
        // In a real implementation, this would execute a swap from USDC to cbBTC
        // For this example, we're simplifying and assuming the swap happened successfully
        
        // Calculate shares to mint based on current NAV
        uint256 shares = previewDeposit(cbBTCAmount);
        
        // Update user's entry data
        _updateUserEntry(user, shares, currentPrice);
        
        // Mint shares to user
        _mint(user, shares);
        
        // Deploy to strategy
        _deployToStrategy(cbBTCAmount);
        
        emit StrikeTriggered(user, usdcAmount, cbBTCAmount, shares);
    }
    
    /**
     * @notice External function to check and trigger strikes
     * @dev Can be called by anyone, typically a keeper
     */
    function checkAndTriggerStrikes() external {
        strikeHook.checkAndTriggerStrikes();
    }
    
    /**
     * @notice Manually trigger a user's strike if price conditions are met
     * @param user Address of user to check
     */
    function manuallyTriggerStrike(address user) external {
        require(pendingDeposits[user] > 0, "No pending deposit");
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        
        require(currentPrice <= strikePoints[user], "Strike price not met");
        _triggerStrike(user);
    }
    
    //----------------------------------------------------------------
    // STRATEGY MANAGEMENT
    //----------------------------------------------------------------
    
    /**
     * @notice Deploy assets to the leveraged strategy - leverage only occurs on entry
     * @param amount Amount of cbBTC to deploy
     */
    function _deployToStrategy(uint256 amount) internal {
        // Approve leverage manager to take tokens
        IERC20(asset()).approve(address(leverageManager), amount);
        
        // Send to leverage manager - this will lever up the position ONCE at entry
        leverageManager.onDeposit(amount);
    }
    
    /**
     * @notice Withdraw assets from the leveraged strategy
     * @param sharePercentage Percentage of position to withdraw (in basis points)
     * @return Amount of cbBTC withdrawn
     */
    function _withdrawFromStrategy(uint256 sharePercentage) internal returns (uint256) {
        return leverageManager.prepareExit(sharePercentage);
    }
    
    //----------------------------------------------------------------
    // FEE CALCULATION
    //----------------------------------------------------------------
    
    /**
     * @notice Calculate performance fee for a withdrawal
     * @param user User who is withdrawing
     * @param cbBTCAmount Amount of cbBTC being withdrawn
     * @param currentPrice Current cbBTC price
     * @return feeAmount Amount of performance fee to charge (stays in vault)
     */
    function _calculatePerformanceFee(
        address user,
        uint256 cbBTCAmount,
        uint256 currentPrice
    ) internal returns (uint256 feeAmount) {
        uint256 entryPrice = userEntryPrices[user];
        
        // No fee if no profit or no entry price record
        if (currentPrice <= entryPrice || entryPrice == 0) {
            return 0;
        }
        
        // Calculate profit portion
        uint256 profitPercentage = ((currentPrice - entryPrice) * 10000) / entryPrice;
        uint256 profitAmount = (cbBTCAmount * profitPercentage) / 10000;
        
        // Calculate fee on profit
        feeAmount = (profitAmount * performanceFee) / 10000;
        
        // Keep the fee in the vault by simply not transferring it out
        // The user's share is already reduced by this amount
        if (feeAmount > 0) {
            // Emit event for tracking purposes
            emit PerformanceFeePaid(user, feeAmount);
        }
        
        return feeAmount;
    }
    
    //----------------------------------------------------------------
    // USER ENTRY/EXIT TRACKING
    //----------------------------------------------------------------
    
    /**
     * @notice Update user entry data for performance fee calculation
     * @param user User address
     * @param newShares Amount of new shares being issued
     * @param currentPrice Current cbBTC price
     */
    function _updateUserEntry(address user, uint256 newShares, uint256 currentPrice) internal {
        uint256 existingShares = balanceOf(user);
        
        if (existingShares == 0) {
            // New entry - set initial price
            userEntryPrices[user] = currentPrice;
            userEntryShares[user] = newShares;
        } else {
            // Additional deposit - calculate weighted average
            userEntryPrices[user] = (userEntryPrices[user] * existingShares + currentPrice * newShares) / (existingShares + newShares);
            userEntryShares[user] += newShares;
        }
    }
    
    /**
     * @notice Update user data when withdrawing
     * @param user User address
     * @param sharesRemoved Amount of shares being removed
     */
    function _updateUserExitData(address user, uint256 sharesRemoved) internal {
        // Adjust entry tracking
        uint256 remainingShares = balanceOf(user) - sharesRemoved;
        
        if (remainingShares == 0) {
            // Full exit - reset entry data
            userEntryPrices[user] = 0;
            userEntryShares[user] = 0;
        } else {
            // Partial exit - maintain entry price
            userEntryShares[user] = remainingShares;
        }
    }
    
    //----------------------------------------------------------------
    // ADMIN FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Set the performance fee that stays in the vault for remaining participants
     * @param _performanceFee New fee in basis points (e.g. 500 = 5%)
     */
    function setPerformanceFee(uint256 _performanceFee) external onlyOwner {
        require(_performanceFee <= 3000, "Fee too high"); // Max 30%
        performanceFee = _performanceFee;
    }
    
    /**
     * @notice Update contract addresses
     * @param _leverageManager New leverage manager address
     * @param _priceOracle New price oracle address
     * @param _strikeHook New strike hook address
     */
    function updateAddresses(
        address _leverageManager,
        address _priceOracle,
        address _strikeHook
    ) external onlyOwner {
        if (_leverageManager != address(0)) leverageManager = ILeverageManager(_leverageManager);
        if (_priceOracle != address(0)) priceOracle = IPriceOracle(_priceOracle);
        if (_strikeHook != address(0)) strikeHook = IStrikePriceHook(_strikeHook);
    }
    
    /**
     * @notice Set the maximum slippage for swaps
     * @param _maxSlippage New maximum slippage in basis points
     */
    function setMaxSlippage(uint256 _maxSlippage) external onlyOwner {
        require(_maxSlippage <= 1000, "Slippage too high"); // Max 10%
        maxSlippage = _maxSlippage;
    }
    
    /**
     * @notice Pause/unpause deposits
     * @param paused New paused state
     */
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
    }
    
    /**
     * @notice Pause/unpause withdrawals
     * @param paused New paused state
     */
    function setWithdrawalsPaused(bool paused) external onlyOwner {
        withdrawalsPaused = paused;
    }
    
    /**
     * @notice Emergency function to withdraw assets from strategy
     * @param sharePercentage Percentage of position to withdraw (in basis points)
     */
    function emergencyWithdraw(uint256 sharePercentage) external onlyOwner {
        require(sharePercentage > 0 && sharePercentage <= 10000, "Invalid percentage");
        leverageManager.prepareExit(sharePercentage);
    }
    
    /**
     * @notice Rescue tokens accidentally sent to the contract
     * @param token Token to rescue
     * @param to Address to send tokens to
     * @param amount Amount of tokens to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(token != asset(), "Cannot rescue vault asset");
        IERC20(token).safeTransfer(to, amount);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }
}