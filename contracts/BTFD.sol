// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BTFD - Cooperative Leverage Trading Vault
 * @notice ERC-4626 compliant vault implementing a "Buy The Dip" strategy with leverage
 * 
 * This system enables:
 * 1. Cooperative leveraged positions - users deposit cbBTC which is then leveraged through Compound III
 *    Later entrants at lower prices effectively improve the position for all participants
 * 
 * 2. Strike price based entry system - users can set price targets at which their USDC is 
 *    automatically converted to cbBTC and added to the position, implementing automated DCA
 * 
 * 3. Individual profit tracking - each user's entry price is recorded to enable accurate 
 *    performance fee calculation based on their specific gains, not collective vault performance
 * 
 * 4. Collective benefit mechanism - performance fees remain in the vault to benefit remaining 
 *    participants, creating incentive for long-term participation
 * 
 * 5. Proportional unwinding - when users exit, only their portion of the leveraged position is
 *    unwound, maintaining position integrity for remaining users
 * 
 * The contract uses a leveraged strategy where cbBTC is supplied as collateral to Compound III, 
 * USDC is borrowed against it, converted to more cbBTC, and supplied again as additional collateral.
 */

/**
 * @dev Interface for interacting with the LeverageManager contract that handles
 * all Compound III interactions and leverage operations
 */
interface ILeverageManager {
    /**
     * @notice Handles new deposits by applying leverage to the collateral
     * @param amount Amount of cbBTC to leverage
     */
    function onDeposit(uint256 amount) external;
    
    /**
     * @notice Unwinds a portion of the leveraged position
     * @param sharePercentage Percentage of the position to unwind (in basis points, e.g. 5000 = 50%)
     * @return cbBTCAmount Amount of cbBTC released after unwinding
     */
    function prepareExit(uint256 sharePercentage) external returns (uint256 cbBTCAmount);
    
    /**
     * @notice Gets current position details from Compound III
     * @return suppliedAmount Total cbBTC supplied as collateral
     * @return borrowedAmount Total USDC borrowed
     */
    function getPositionDetails() external view returns (uint256 suppliedAmount, uint256 borrowedAmount);
}

/**
 * @dev Interface for the price oracle that provides the cbBTC/USDC exchange rate
 */
interface IPriceOracle {
    /**
     * @notice Gets the current price of cbBTC in USDC
     * @return Current price with 18 decimals of precision
     */
    function getCbBTCPrice() external view returns (uint256);
}

/**
 * @dev Interface for the StrikePriceHook that monitors prices and triggers conversions
 */
interface IStrikePriceHook {
    /**
     * @notice Checks current prices against user-set strike prices and executes conversions
     */
    function checkAndTriggerStrikes() external;
}

/**
 * @title BTFD
 * @notice Main vault contract implementing ERC-4626 standard for a leveraged Bitcoin strategy
 * @dev Inherits ERC4626 for standard vault functionality, Ownable for admin functions,
 *      and ReentrancyGuard for protection against reentrancy attacks
 */
contract BTFD is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //----------------------------------------------------------------
    // STATE VARIABLES
    //----------------------------------------------------------------
    
    /**
     * @notice The LeverageManager contract that handles all Compound III interactions
     * @dev Responsible for supplying collateral, borrowing, and managing the leveraged position
     */
    ILeverageManager public leverageManager;
    
    /**
     * @notice The price oracle that provides cbBTC/USDC price data
     */
    IPriceOracle public priceOracle;
    
    /**
     * @notice The hook contract that monitors prices and triggers strikes
     */
    IStrikePriceHook public strikeHook;
    
    /**
     * @notice Address of the cbBTC token (the underlying asset of the vault)
     */
    address public cbBTCToken;
    
    /**
     * @notice Address of the USDC token (used for pending deposits and borrowing)
     */
    address public usdcToken;
    
    /**
     * @notice Performance fee charged on profits when users withdraw
     * @dev Expressed in basis points (e.g., 500 = 5%)
     * The fee is calculated only on profits (current value - entry value)
     * and remains in the vault to benefit remaining participants
     */
    uint256 public performanceFee;
    
    /**
     * @notice Records each user's cbBTC price at entry
     * @dev Used to calculate profits and performance fees accurately
     * For users who enter multiple times, this stores a weighted average
     */
    mapping(address => uint256) public userEntryPrices;
    
    /**
     * @notice Records the number of shares each user holds at their entry
     * @dev Used for tracking user positions and calculating weighted averages
     * on additional deposits
     */
    mapping(address => uint256) public userEntryShares;
    
    /**
     * @notice Stores each user's target prices for cbBTC purchases
     * @dev Price is in USDC per cbBTC (e.g., 60000 = $60,000 per BTC)
     * When price drops to or below this value, pending USDC is converted
     */
    mapping(address => uint256) public strikePoints;
    
    /**
     * @notice Amount of USDC each user has deposited waiting for conversion
     * @dev When the price hits the strike point, this USDC is converted to cbBTC
     */
    mapping(address => uint256) public pendingDeposits;
    
    /**
     * @notice Maximum allowed slippage for swaps in basis points (e.g., 300 = 3%)
     * @dev Used to prevent excessive slippage in on-chain swaps
     */
    uint256 public maxSlippage;
    
    /**
     * @notice Flag to pause new deposits
     * @dev Can be set by owner in case of emergencies or contract upgrades
     */
    bool public depositsPaused;
    
    /**
     * @notice Flag to pause withdrawals
     * @dev Can be set by owner in case of emergencies or to prevent bank runs
     */
    bool public withdrawalsPaused;
    
    /**
     * @notice Emitted when a user sets a strike price
     * @param user Address of the user setting the strike
     * @param price The strike price in USDC per cbBTC
     */
    event StrikePriceSet(address indexed user, uint256 price);
    
    /**
     * @notice Emitted when a user adds USDC waiting for a strike
     * @param user Address of the user making the deposit
     * @param usdcAmount Amount of USDC deposited
     */
    event PendingDepositAdded(address indexed user, uint256 usdcAmount);
    
    /**
     * @notice Emitted when a strike price is hit and conversion occurs
     * @param user Address of the user whose strike was triggered
     * @param usdcAmount Amount of USDC converted
     * @param cbBTCAmount Amount of cbBTC received
     * @param shares Number of vault shares minted to the user
     */
    event StrikeTriggered(address indexed user, uint256 usdcAmount, uint256 cbBTCAmount, uint256 shares);
    
    /**
     * @notice Emitted when a performance fee is charged on withdrawal
     * @param user Address of the user paying the fee
     * @param cbBTCAmount Amount of fee paid in cbBTC
     */
    event PerformanceFeePaid(address indexed user, uint256 cbBTCAmount);
    
    /**
     * @notice Emitted when a withdrawal is processed
     * @param user Address of the user withdrawing
     * @param shares Number of shares redeemed
     * @param cbBTCAmount Amount of cbBTC returned to the user
     */
    event WithdrawalProcessed(address indexed user, uint256 shares, uint256 cbBTCAmount);
    
    /**
     * @notice Emitted when performance fees increase the NAV for remaining users
     * @param feeAmount Amount of fees retained in the vault
     * @param newNavPerShare New NAV per share after fee retention
     */
    event NAVIncreasedFromFees(uint256 feeAmount, uint256 newNavPerShare);
    
    //----------------------------------------------------------------
    // CONSTRUCTOR & SETUP
    //----------------------------------------------------------------
    
    /**
     * @notice Initialize the BTFD vault
     * @param _cbBTCToken Address of the cbBTC token (vault's underlying asset)
     * @param _usdcToken Address of the USDC token (for pending deposits and borrowing)
     * @param _leverageManager Address of the LeverageManager contract
     * @param _priceOracle Address of the price oracle for cbBTC/USDC
     * @param _strikeHook Address of the strike price monitoring contract
     * @param _name ERC20 name for the vault shares token
     * @param _symbol ERC20 symbol for the vault shares token
     * @dev Sets up the vault with default 5% performance fee and 3% max slippage
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
        
        performanceFee = 500; // 5% by default (in basis points)
        maxSlippage = 300; // 3% by default (in basis points)
    }
    
    //----------------------------------------------------------------
    // ERC4626 OVERRIDES
    //----------------------------------------------------------------
    
    /**
     * @notice Calculates the total assets managed by the vault
     * @return Total value of assets in the vault (including leveraged position)
     * @dev Overrides ERC4626 totalAssets() to account for the leveraged strategy
     * This includes:
     *   1. cbBTC held directly in the vault
     *   2. Net value of the leveraged position (supplied cbBTC minus borrowed USDC converted to cbBTC)
     */
    function totalAssets() public view override returns (uint256) {
        // Get the current position details from the leverage manager
        (uint256 suppliedAmount, uint256 borrowedAmount) = leverageManager.getPositionDetails();
        
        // Get current price of cbBTC in USDC
        uint256 cbBTCPrice = priceOracle.getCbBTCPrice();
        
        // Get cbBTC balance held directly in the vault
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        
        // Calculate net value of leveraged position
        // This is: supplied cbBTC - (borrowed USDC / cbBTC price)
        uint256 leveragedAssets = suppliedAmount > 0 ? suppliedAmount - (borrowedAmount / cbBTCPrice) : 0;
        
        // Total assets = direct vault balance + net leveraged position
        return vaultBalance + leveragedAssets;
    }
    
    /**
     * @notice Deposits cbBTC into the vault
     * @param assets Amount of cbBTC to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of vault shares minted
     * @dev Overrides ERC4626 deposit() to implement entry price tracking and leverage
     * The process:
     *   1. Records current cbBTC price for entry tracking and performance fee calculation
     *   2. Calculates and mints shares
     *   3. Updates user's position data
     *   4. Transfers cbBTC from user to vault
     *   5. Deploys cbBTC to the leveraged strategy
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        require(!depositsPaused, "Deposits are paused");
        require(assets > 0, "Cannot deposit 0 assets");
        
        // Record current cbBTC price for entry tracking and performance fee calculation
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        
        // Calculate shares to mint based on current NAV
        uint256 shares = previewDeposit(assets);
        require(shares > 0, "Zero shares");
        
        // Update user's entry data for performance fee calculation
        _updateUserEntry(receiver, shares, currentPrice);
        
        // Transfer assets from sender to vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        
        // Mint shares to receiver
        _mint(receiver, shares);
        
        // Deploy assets to the leveraged strategy
        _deployToStrategy(assets);
        
        emit Deposit(msg.sender, receiver, assets, shares);
        
        return shares;
    }
    
    /**
     * @notice Withdraws cbBTC from the vault
     * @param assets Amount of cbBTC to withdraw
     * @param receiver Address to receive the cbBTC
     * @param owner Address that owns the shares
     * @return shares Amount of vault shares burned
     * @dev Overrides ERC4626 withdraw() to implement proportional unwinding and performance fees
     * The process:
     *   1. Calculates shares to burn based on assets requested
     *   2. Checks allowance if caller is not the owner
     *   3. Calculates user's percentage of the total position
     *   4. Unwinds that percentage of the leveraged position
     *   5. Calculates performance fee based on entry price vs current price
     *   6. Updates user's position data
     *   7. Burns shares and transfers cbBTC to receiver
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256) {
        require(!withdrawalsPaused, "Withdrawals are paused");
        require(assets > 0, "Cannot withdraw 0 assets");
        
        // Calculate shares to burn based on requested assets
        uint256 shares = previewWithdraw(assets);
        require(shares > 0, "Zero shares");
        
        // If caller is not the owner, check allowance
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        
        // Calculate what percentage of the total position the user is withdrawing
        // This is in basis points (e.g., 5000 = 50%)
        uint256 sharePercentage = (shares * 10000) / totalSupply();
        
        // Get current price for performance fee calculation
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        
        // Unwind the proportional part of the leveraged position
        uint256 cbBTCReceived = _withdrawFromStrategy(sharePercentage);
        
        // Calculate performance fee based on user's entry price vs current price
        uint256 feeAmount = _calculatePerformanceFee(owner, cbBTCReceived, currentPrice);
        
        // Final amount after deducting performance fee
        uint256 finalAmount = cbBTCReceived - feeAmount;
        
        // Update user's entry data (for partial withdrawals)
        _updateUserExitData(owner, shares);
        
        // Burn the shares
        _burn(owner, shares);
        
        // Transfer cbBTC to receiver
        IERC20(asset()).safeTransfer(receiver, finalAmount);
        
        // If there's a performance fee and remaining users, update the NAV
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
     * @notice Sets a target price at which to convert USDC to cbBTC
     * @param strikePrice Price in USDC per cbBTC (e.g., 60000 = $60,000 per BTC)
     * @dev This enables automated "buy the dip" functionality
     * Users set their desired entry price, then deposit USDC which waits
     * for conversion when price drops to or below the strike price
     */
    function setStrikePoint(uint256 strikePrice) external {
        require(strikePrice > 0, "Strike price must be greater than 0");
        strikePoints[msg.sender] = strikePrice;
        
        emit StrikePriceSet(msg.sender, strikePrice);
    }
    
    /**
     * @notice Deposits USDC to wait for a price drop to the strike point
     * @param usdcAmount Amount of USDC to deposit
     * @dev USDC remains in the vault until the price hits the strike point
     * At that point, it's converted to cbBTC, shares are minted, and
     * the resulting position is leveraged
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
     * @notice Converts a user's USDC to cbBTC when strike price is hit
     * @param user Address of the user whose strike is triggered
     * @dev Internal function called when price drops to/below strike price
     * Process:
     *   1. Reset user's pending deposit (to prevent reentrancy)
     *   2. Get current price and calculate cbBTC amount
     *   3. In production, execute swap from USDC to cbBTC
     *   4. Calculate shares based on current NAV
     *   5. Update user's entry data
     *   6. Mint shares and deploy to leveraged strategy
     */
    function _triggerStrike(address user) internal {
        uint256 usdcAmount = pendingDeposits[user];
        require(usdcAmount > 0, "No pending deposit");
        
        // Reset pending deposit first to prevent reentrancy
        pendingDeposits[user] = 0;
        
        // Get current price
        uint256 currentPrice = priceOracle.getCbBTCPrice();
        
        // Calculate cbBTC amount based on current price
        uint256 cbBTCAmount = (usdcAmount * 1e18) / currentPrice;
        
        // In a real implementation, this would execute a swap from USDC to cbBTC
        // For this example, we're simplifying and assuming the swap happened successfully
        
        // Calculate shares to mint based on current NAV
        uint256 shares = previewDeposit(cbBTCAmount);
        
        // Update user's entry data for performance fee calculation
        _updateUserEntry(user, shares, currentPrice);
        
        // Mint shares to user
        _mint(user, shares);
        
        // Deploy to leveraged strategy
        _deployToStrategy(cbBTCAmount);
        
        emit StrikeTriggered(user, usdcAmount, cbBTCAmount, shares);
    }
    
    /**
     * @notice Triggers the StrikePriceHook to check for strike conditions
     * @dev Can be called by keepers or any external system
     * The hook checks all users' strike prices against current price
     * and triggers conversions for any that meet the criteria
     */
    function checkAndTriggerStrikes() external {
        strikeHook.checkAndTriggerStrikes();
    }
    
    /**
     * @notice Manually triggers a user's strike if price conditions are met
     * @param user Address of user to check
     * @dev Allows anyone to trigger conversion for a specific user
     * if their strike price has been hit
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
     * @notice Deploys cbBTC to the leveraged strategy
     * @param amount Amount of cbBTC to deploy
     * @dev Internal function that:
     *   1. Approves the LeverageManager to take the cbBTC
     *   2. Calls onDeposit which initiates the leverage strategy
     * The LeverageManager will:
     *   - Supply cbBTC as collateral to Compound III
     *   - Borrow USDC against the cbBTC
     *   - Swap USDC for more cbBTC
     *   - Supply additional cbBTC as collateral
     */
    function _deployToStrategy(uint256 amount) internal {
        // Approve leverage manager to take tokens
        IERC20(asset()).approve(address(leverageManager), amount);
        
        // Send to leverage manager - this will lever up the position ONCE at entry
        leverageManager.onDeposit(amount);
    }
    
    /**
     * @notice Withdraws a percentage of assets from the leveraged strategy
     * @param sharePercentage Percentage of position to withdraw (in basis points)
     * @return Amount of cbBTC withdrawn
     * @dev Internal function that calls LeverageManager to:
     *   1. Calculate the user's share of collateral and debt
     *   2. Partially unwind the leveraged position
     *   3. Return the resulting cbBTC to the vault
     */
    function _withdrawFromStrategy(uint256 sharePercentage) internal returns (uint256) {
        return leverageManager.prepareExit(sharePercentage);
    }
    
    //----------------------------------------------------------------
    // FEE CALCULATION
    //----------------------------------------------------------------
    
    /**
     * @notice Calculates performance fee for a withdrawal
     * @param user User who is withdrawing
     * @param cbBTCAmount Amount of cbBTC being withdrawn
     * @param currentPrice Current cbBTC price
     * @return feeAmount Amount of performance fee to charge (stays in vault)
     * @dev Fee calculation process:
     *   1. Get user's entry price
     *   2. If current price <= entry price, no fee (no profit)
     *   3. Calculate profit percentage: (current - entry) / entry
     *   4. Calculate profit amount: cbBTC amount * profit percentage
     *   5. Calculate fee: profit amount * fee rate
     * The fee stays in the vault to benefit remaining participants
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
        
        // Calculate profit percentage
        // Example: if entry=$50k, current=$60k: profitPercentage = (60k-50k)/50k * 10000 = 2000 (20%)
        uint256 profitPercentage = ((currentPrice - entryPrice) * 10000) / entryPrice;
        
        // Calculate profit portion of the withdrawn amount
        // Example: if withdrawing 1 cbBTC with 20% profit: profitAmount = 1 * 2000/10000 = 0.2 cbBTC
        uint256 profitAmount = (cbBTCAmount * profitPercentage) / 10000;
        
        // Calculate fee on profit
        // Example: if fee is 5% (500bp): feeAmount = 0.2 * 500/10000 = 0.01 cbBTC
        feeAmount = (profitAmount * performanceFee) / 10000;
        
        // The fee stays in the vault, benefiting remaining participants
        // We simply deduct it from the amount sent to the user
        if (feeAmount > 0) {
            emit PerformanceFeePaid(user, feeAmount);
        }
        
        return feeAmount;
    }
    
    //----------------------------------------------------------------
    // USER ENTRY/EXIT TRACKING
    //----------------------------------------------------------------
    
    /**
     * @notice Updates a user's entry data when depositing
     * @param user User address
     * @param newShares Amount of new shares being issued
     * @param currentPrice Current cbBTC price
     * @dev Handles both initial entries and additional deposits:
     *   - For new users: sets initial entry price
     *   - For existing users: calculates weighted average entry price
     */
    function _updateUserEntry(address user, uint256 newShares, uint256 currentPrice) internal {
        uint256 existingShares = balanceOf(user);
        
        if (existingShares == 0) {
            // New entry - set initial price
            userEntryPrices[user] = currentPrice;
            userEntryShares[user] = newShares;
        } else {
            // Additional deposit - calculate weighted average entry price
            // Example: if existing 1 share at $50k and adding 1 share at $60k:
            // New entry price = (50k*1 + 60k*1)/(1+1) = $55k
            userEntryPrices[user] = (userEntryPrices[user] * existingShares + currentPrice * newShares) / (existingShares + newShares);
            userEntryShares[user] += newShares;
        }
    }
    
    /**
     * @notice Updates a user's data when withdrawing
     * @param user User address
     * @param sharesRemoved Amount of shares being removed
     * @dev Handles both full and partial withdrawals:
     *   - For full exits: resets entry data
     *   - For partial exits: updates share count but maintains entry price
     */
    function _updateUserExitData(address user, uint256 sharesRemoved) internal {
        // Calculate remaining shares after withdrawal
        uint256 remainingShares = balanceOf(user) - sharesRemoved;
        
        if (remainingShares == 0) {
            // Full exit - reset entry data
            userEntryPrices[user] = 0;
            userEntryShares[user] = 0;
        } else {
            // Partial exit - maintain entry price but update share count
            userEntryShares[user] = remainingShares;
        }
    }
    
    //----------------------------------------------------------------
    // ADMIN FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Sets the performance fee rate
     * @param _performanceFee New fee in basis points (e.g. 500 = 5%)
     * @dev Fee is charged only on profits, not total withdrawal amount
     * Maximum allowed fee is 30% (3000 basis points)
     */
    function setPerformanceFee(uint256 _performanceFee) external onlyOwner {
        require(_performanceFee <= 3000, "Fee too high"); // Max 30%
        performanceFee = _performanceFee;
    }
    
    /**
     * @notice Updates addresses of integrated contracts
     * @param _leverageManager New leverage manager address
     * @param _priceOracle New price oracle address
     * @param _strikeHook New strike hook address
     * @dev Only non-zero addresses are updated
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
     * @notice Sets the maximum allowed slippage for swaps
     * @param _maxSlippage New maximum slippage in basis points
     * @dev Used for determining minimum acceptable output in swaps
     * Maximum allowed setting is 10% (1000 basis points)
     */
    function setMaxSlippage(uint256 _maxSlippage) external onlyOwner {
        require(_maxSlippage <= 1000, "Slippage too high"); // Max 10%
        maxSlippage = _maxSlippage;
    }
    
    /**
     * @notice Pauses or unpauses deposits
     * @param paused New paused state
     * @dev Can be used in emergencies or during upgrades
     */
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
    }
    
    /**
     * @notice Pauses or unpauses withdrawals
     * @param paused New paused state
     * @dev Can be used in emergencies or to prevent bank runs
     */
    function setWithdrawalsPaused(bool paused) external onlyOwner {
        withdrawalsPaused = paused;
    }
    
    /**
     * @notice Emergency function to withdraw assets from strategy
     * @param sharePercentage Percentage of position to withdraw (in basis points)
     * @dev Allows owner to force unwinding in emergency situations
     * Withdrawn assets remain in the vault (not distributed to users)
     */
    function emergencyWithdraw(uint256 sharePercentage) external onlyOwner {
        require(sharePercentage > 0 && sharePercentage <= 10000, "Invalid percentage");
        leverageManager.prepareExit(sharePercentage);
    }
    
    /**
     * @notice Rescues tokens accidentally sent to the contract
     * @param token Token to rescue
     * @param to Address to send tokens to
     * @param amount Amount of tokens to rescue
     * @dev Prevents rescuing the vault's underlying asset (cbBTC)
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(token != asset(), "Cannot rescue vault asset");
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Converts asset amount to share amount
     * @param assets Amount of cbBTC to convert
     * @return Equivalent amount of shares
     * @dev Overrides ERC4626 convertToShares()
     * Formula: assets * totalSupply / totalAssets
     * If no supply exists, return assets (1:1 ratio for first deposit)
     */
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }
}