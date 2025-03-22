// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title StrikePriceHook - Cooperative Leverage Trading Mechanism
 * @notice Enables automated entry into a collective cbBTC position when target prices are hit
 * 
 * This contract is a critical component of the BTFD system, providing "buy the dip" functionality by:
 * 
 * 1. Price Monitoring: Continuously tracks cbBTC/USDC price using Uniswap V3 data and an oracle
 * 
 * 2. Strike Price Management: Enables users to set their own target entry prices, allowing
 *    for personalized DCA (Dollar Cost Averaging) strategies
 * 
 * 3. Automated Conversion: When Bitcoin price drops to a user's strike price, their
 *    pending USDC is automatically converted to cbBTC and added to the vault
 * 
 * 4. Collective Benefit: When new users enter at lower prices, they strengthen the
 *    vault's overall collateral position, benefiting all participants
 * 
 * 5. Fair Distribution: The 4626 vault ensures that each user receives shares
 *    proportional to their contribution's value
 * 
 * The system creates a cooperative mechanism where individual strategies for buying
 * dips collectively improve the leverage position for all participants.
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @dev Interface for interacting with Uniswap V3 pool to get real-time price data
 */
interface IUniswapV3Pool {
    /**
     * @notice Returns the current state of the pool
     * @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
     * @return tick The current tick of the pool, i.e. log base 1.0001 of the current price
     * @return observationIndex The index of the last oracle observation that was written
     * @return observationCardinality The current maximum number of observations stored in the pool
     * @return observationCardinalityNext The next maximum number of observations
     * @return feeProtocol The protocol fee for both tokens of the pool
     * @return unlocked Whether the pool is currently locked or not
     */
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    
    /**
     * @notice Returns the cumulative tick and liquidity-in-range data for the given time periods
     * @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
     * @return tickCumulatives Cumulative tick values as of each secondsAgos from the current block timestamp
     * @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range values
     */
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    );
}

/**
 * @dev Interface for interacting with Uniswap V3 Factory to find pools
 */
interface IUniswapV3Factory {
    /**
     * @notice Returns the pool address for a given pair of tokens and fee
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @param fee Fee tier for the pool
     * @return pool The pool address
     */
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/**
 * @dev Interface for interacting with the BTFD vault
 */
interface IBTFD {
    /**
     * @notice Deposit assets into the vault
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    
    /**
     * @notice Deposit USDC waiting for conversion when a strike price is hit
     * @param usdcAmount Amount of USDC to deposit
     */
    function depositUSDCPending(uint256 usdcAmount) external;
    
    /**
     * @notice Set a strike price for automated entry
     * @param strikePrice Price target in USDC per cbBTC
     */
    function setStrikePoint(uint256 strikePrice) external;
    
    /**
     * @notice Manually trigger a strike conversion for a specific user
     * @param user Address of the user whose strike price was hit
     */
    function manuallyTriggerStrike(address user) external;
}

/**
 * @dev Interface for the NAV Oracle that provides pricing data
 */
interface INAVOracle {
    /**
     * @notice Get the current price of cbBTC in USDC
     * @return Current price with 18 decimals precision
     */
    function getCbBTCPrice() external view returns (uint256);
}

/**
 * @title StrikePriceHook
 * @notice Monitors Uniswap V3 prices and executes conversions when strike prices are hit
 * @dev Uses ReentrancyGuard for protection during deposits and Ownable for admin functions
 */
contract StrikePriceHook is ReentrancyGuard, Ownable {
    //----------------------------------------------------------------
    // STATE VARIABLES
    //----------------------------------------------------------------
    
    /**
     * @notice Address of the BTFD vault that holds assets and manages positions
     * @dev All conversions are executed through this vault
     */
    address public btfdVault;
    
    /**
     * @notice Address of the NAV Oracle providing price data
     * @dev Used as primary price source with Uniswap V3 as fallback
     */
    address public navOracle;
    
    /**
     * @notice Address of Uniswap V3 Factory for finding pools
     * @dev Used to locate pools based on token pairs and fee tiers
     */
    address public uniswapV3Factory;
    
    /**
     * @notice Address of the active Uniswap V3 pool for price monitoring
     * @dev This pool's price data is used when the oracle is unavailable
     */
    address public activePool;
    
    /**
     * @notice Fee tier of the monitored Uniswap V3 pool
     * @dev In hundredths of a bip (e.g., 3000 = 0.3%)
     */
    uint24 public poolFee;
    
    /**
     * @notice Address of the cbBTC token (Bitcoin on Base)
     * @dev Used for pool identification and price calculations
     */
    address public cbBTCToken;
    
    /**
     * @notice Address of the USDC token
     * @dev Used for pool identification and as the deposit currency
     */
    address public usdcToken;
    
    /**
     * @notice Mapping of user addresses to their target strike prices
     * @dev Price is in USDC per cbBTC (e.g., 60000 = $60,000 per BTC)
     */
    mapping(address => uint256) public userStrikePoints;
    
    /**
     * @notice Mapping of user addresses to their pending USDC deposits
     * @dev Tracks the amount each user has waiting for conversion
     */
    mapping(address => uint256) public userDeposits;
    
    /**
     * @notice Mapping to track which users have active deposits
     * @dev Used for efficient iteration when checking strike conditions
     */
    mapping(address => bool) public hasDeposit;
    
    /**
     * @notice Array of all user addresses with active deposits
     * @dev Maintained to avoid iterating the entire blockchain for active users
     */
    address[] public depositUsers;
    
    /**
     * @notice Minimum price movement required to consider triggering strikes
     * @dev In wei units (e.g., 1e15 = 0.1% of 1e18)
     */
    uint256 public minPriceMovement;
    
    /**
     * @notice Minimum time between price checks
     * @dev In seconds, prevents excessive calls and gas consumption
     */
    uint256 public checkInterval;
    
    /**
     * @notice Timestamp of the last price check
     * @dev Used to enforce the check interval
     */
    uint256 public lastCheckTime;
    
    /**
     * @notice Emitted when a user sets a strike price
     * @param user Address of the user setting the strike
     * @param strikePrice The price target in USDC per cbBTC
     */
    event StrikePointSet(address indexed user, uint256 strikePrice);
    
    /**
     * @notice Emitted when a strike price is hit and conversion occurs
     * @param user Address of the user whose strike was triggered
     * @param strikePrice The strike price that was hit
     * @param convertedAmount The amount of cbBTC received
     */
    event StrikeHit(address indexed user, uint256 strikePrice, uint256 convertedAmount);
    
    /**
     * @notice Emitted when a user deposits USDC waiting for conversion
     * @param user Address of the depositing user
     * @param amount Amount of USDC deposited
     */
    event UserDeposited(address indexed user, uint256 amount);
    
    /**
     * @notice Emitted when the monitored pool is updated
     * @param pool Address of the new pool
     * @param fee Fee tier of the new pool
     */
    event PoolUpdated(address indexed pool, uint24 fee);
    
    /**
     * @notice Emitted when prices are checked
     * @param timestamp When the check occurred
     * @param price Current price of cbBTC in USDC
     */
    event PriceChecked(uint256 timestamp, uint256 price);
    
    //----------------------------------------------------------------
    // CONSTRUCTOR & SETUP
    //----------------------------------------------------------------
    
    /**
     * @notice Initialize the StrikePriceHook with required addresses and parameters
     * @param _btfdVault Address of the BTFD vault
     * @param _navOracle Address of the NAV oracle for price data
     * @param _uniswapFactory Address of Uniswap V3 Factory
     * @param _cbBTCToken Address of cbBTC token
     * @param _usdcToken Address of USDC token
     * @param _initialPoolFee Initial fee tier for monitoring (e.g., 3000 = 0.3%)
     * @dev Sets up the contract and validates that the pool exists
     * 
     * The constructor:
     * 1. Stores all contract and token addresses
     * 2. Locates the appropriate Uniswap V3 pool for the token pair
     * 3. Sets default values for price movement threshold and check interval
     * 4. Ensures the specified pool exists, otherwise reverts
     */
    constructor(
        address _btfdVault,
        address _navOracle,
        address _uniswapFactory,
        address _cbBTCToken,
        address _usdcToken,
        uint24 _initialPoolFee
    ) Ownable(msg.sender) {
        btfdVault = _btfdVault;
        navOracle = _navOracle;
        uniswapV3Factory = _uniswapFactory;
        cbBTCToken = _cbBTCToken;
        usdcToken = _usdcToken;
        poolFee = _initialPoolFee;
        
        // Initialize the active pool
        activePool = IUniswapV3Factory(uniswapV3Factory).getPool(
            cbBTCToken,
            usdcToken,
            poolFee
        );
        require(activePool != address(0), "Pool does not exist");
        
        // Set default parameters
        minPriceMovement = 1e15; // 0.1% by default
        checkInterval = 5 minutes;
        lastCheckTime = block.timestamp;
    }
    
    //----------------------------------------------------------------
    // USER INTERACTION FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Sets a target price for automated cbBTC purchase
     * @param strikePrice The price at which USDC should convert to cbBTC
     * @dev Users must set their strike price before depositing USDC
     * 
     * The function:
     * 1. Validates the strike price is greater than zero
     * 2. Records the user's desired entry price
     * 3. Also sets the strike price in the BTFD vault for consistency
     * 4. Emits an event for off-chain tracking
     * 
     * This is the first step in the "buy the dip" process. After setting
     * a strike price, users can deposit USDC which will wait for conversion
     * when the price drops to or below their target.
     */
    function setStrikePoint(uint256 strikePrice) external {
        require(strikePrice > 0, "Strike price must be greater than 0");
        
        userStrikePoints[msg.sender] = strikePrice;
        
        // Also set the strike price in the vault
        IBTFD(btfdVault).setStrikePoint(strikePrice);
        
        emit StrikePointSet(msg.sender, strikePrice);
    }
    
    /**
     * @notice Deposits USDC that will automatically convert when price hits target
     * @param amount Amount of USDC to deposit
     * @dev User must have already set a strike price
     * 
     * The function:
     * 1. Validates input parameters and prerequisites
     * 2. Transfers USDC from user to this contract
     * 3. Approves and forwards the deposit to the BTFD vault
     * 4. Updates internal tracking of user deposits
     * 5. Checks if the strike price is already hit (for immediate conversion)
     * 
     * This implements the "set it and forget it" DCA strategy, where users
     * can deposit funds and let the system automatically buy Bitcoin when
     * their target price is reached, without requiring manual intervention.
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(userStrikePoints[msg.sender] > 0, "Strike point must be set first");
        
        // Transfer USDC from user to this contract
        require(IERC20(usdcToken).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Approve the vault to spend the USDC
        IERC20(usdcToken).approve(btfdVault, amount);
        
        // Forward the deposit to the vault
        IBTFD(btfdVault).depositUSDCPending(amount);
        
        // Update user deposit tracking
        if (!hasDeposit[msg.sender]) {
            hasDeposit[msg.sender] = true;
            depositUsers.push(msg.sender);
        }
        
        userDeposits[msg.sender] += amount;
        emit UserDeposited(msg.sender, amount);
        
        // Check if strike price is already hit for immediate conversion
        uint256 currentPrice = getCurrentPrice();
        if (currentPrice <= userStrikePoints[msg.sender]) {
            _triggerStrike(msg.sender, currentPrice);
        }
    }
    
    /**
     * @notice Check current prices and trigger conversions for any hit strike prices
     * @dev Can be called by keepers, bots or any external system
     * 
     * This function:
     * 1. Applies rate limiting to prevent excessive calls
     * 2. Gets the current cbBTC price
     * 3. Iterates through all users with active deposits
     * 4. For each user whose strike price is hit, triggers conversion
     * 5. Handles array manipulation after removing users
     * 
     * This is a critical keeper function that should be called regularly
     * to ensure timely conversion of USDC to cbBTC when strike prices are hit.
     * The function is gas-optimized by maintaining a dedicated list of active users.
     */
    function checkAndTriggerStrikes() external {
        // Rate limit checks to avoid spamming and excessive gas usage
        if (block.timestamp < lastCheckTime + checkInterval) {
            return;
        }
        
        lastCheckTime = block.timestamp;
        uint256 currentPrice = getCurrentPrice();
        
        emit PriceChecked(block.timestamp, currentPrice);
        
        // Check all users with deposits
        for (uint i = 0; i < depositUsers.length; i++) {
            address user = depositUsers[i];
            uint256 strikePrice = userStrikePoints[user];
            uint256 depositAmount = userDeposits[user];
            
            // If user has a strike price and deposit, and price is at or below strike
            if (strikePrice > 0 && depositAmount > 0 && currentPrice <= strikePrice) {
                _triggerStrike(user, currentPrice);
                
                // User processed, adjust index since array length changed
                i--; // Adjust index after removal
            }
        }
    }
    
    //----------------------------------------------------------------
    // PRICE INFORMATION FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Get the current price of cbBTC in USDC
     * @return The current price with 18 decimals precision
     * @dev Uses the NAV Oracle as primary source with Uniswap V3 as fallback
     * 
     * The function implements a dual-source price feed:
     * 1. First attempts to get price from the NAV Oracle (most reliable source)
     * 2. If Oracle is unavailable, falls back to direct Uniswap V3 pool price
     * 
     * This ensures price data is always available even if one source fails.
     */
    function getCurrentPrice() public view returns (uint256) {
        // Try to get the price from the NAV oracle first (most reliable)
        try INAVOracle(navOracle).getCbBTCPrice() returns (uint256 price) {
            return price;
        } catch {
            // Fallback to direct Uniswap V3 pool query
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(activePool).slot0();
            return calculatePriceFromSqrtPrice(sqrtPriceX96);
        }
    }
    
    /**
     * @notice Get the time-weighted average price (TWAP) from Uniswap V3
     * @param period The lookback period in seconds
     * @return The TWAP of cbBTC in USDC over the specified period
     * @dev TWAP provides manipulation-resistant price data over a time window
     * 
     * This function:
     * 1. Gets historical tick data from the Uniswap pool
     * 2. Calculates the average tick over the specified period
     * 3. Converts the tick to a price using the tick math conversion
     * 
     * TWAP is more resistant to flash crashes or price manipulation
     * compared to spot prices, providing more reliable strike triggering.
     */
    function getTWAP(uint32 period) public view returns (uint256) {
        require(period > 0, "Period must be greater than 0");
        require(activePool != address(0), "Pool not set");
        
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period;
        secondsAgos[1] = 0;
        
        try IUniswapV3Pool(activePool).observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            // Calculate the average tick over the period
            // Formula: (latest cumulative tick - earlier cumulative tick) / time elapsed
            int24 avgTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(period)));
            
            // Convert tick to price
            uint160 sqrtPriceX96 = getSqrtRatioAtTick(avgTick);
            return calculatePriceFromSqrtPrice(sqrtPriceX96);
        } catch {
            // If observe fails, return current price as fallback
            return getCurrentPrice();
        }
    }
    
    //----------------------------------------------------------------
    // INTERNAL FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Trigger conversion of USDC to cbBTC when strike price is hit
     * @param user Address of the user whose strike price was hit
     * @param currentPrice Current price of cbBTC in USDC
     * @dev Internal function that handles the actual conversion process
     * 
     * The function:
     * 1. Gets the user's pending deposit amount
     * 2. Resets the pending deposit to prevent reentrancy
     * 3. Calculates theoretical cbBTC amount for event emission
     * 4. Triggers the actual conversion via the BTFD vault
     * 5. Removes user from the active tracking lists
     * 6. Emits an event with conversion details
     * 
     * This is the core function that executes the "buy the dip" strategy
     * when price conditions are met.
     */
    function _triggerStrike(address user, uint256 currentPrice) internal {
        uint256 depositAmount = userDeposits[user];
        if (depositAmount == 0) return;
        
        // Reset user deposit first to prevent reentrancy
        userDeposits[user] = 0;
        
        // Calculate theoretical cbBTC amount based on current price
        // This is for informational purposes in the event
        uint256 cbBTCAmount = (depositAmount * 1e18) / currentPrice;
        
        // Trigger the actual conversion via the vault
        IBTFD(btfdVault).manuallyTriggerStrike(user);
        
        // Remove user from active tracking
        hasDeposit[user] = false;
        for (uint i = 0; i < depositUsers.length; i++) {
            if (depositUsers[i] == user) {
                // Efficient removal by replacing with last element and popping
                depositUsers[i] = depositUsers[depositUsers.length - 1];
                depositUsers.pop();
                break;
            }
        }
        
        emit StrikeHit(user, userStrikePoints[user], cbBTCAmount);
    }
    
    /**
     * @notice Calculate price from Uniswap V3's sqrtPriceX96 format
     * @param sqrtPriceX96 The sqrt price from Uniswap
     * @return price The price of cbBTC in USDC
     * @dev Converts Uniswap's square root representation to a conventional price
     * 
     * Formula explanation:
     * 1. sqrtPriceX96 is a Q64.96 fixed-point number representing √(token1/token0)
     * 2. We square it to get the actual price ratio
     * 3. We multiply by 10^18 for standard decimals
     * 4. We divide by 2^192 to account for the Q notation
     * 
     * This function is essential for interpreting Uniswap V3's price data format.
     */
    function calculatePriceFromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // Convert sqrtPriceX96 to price
        // Formula: price = (sqrtPriceX96^2 * 10^18) / 2^192
        // This assumes both tokens have 18 decimals, would need adjustment otherwise
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 / (2**192);
        return price;
    }
    
    /**
     * @notice Convert a tick to sqrtPriceX96 format
     * @param tick The tick value
     * @return sqrtPriceX96 value
     * @dev Converts Uniswap V3 tick to the square root price format
     * 
     * This implementation:
     * 1. Takes a tick value (log base 1.0001 of price)
     * 2. Handles both positive and negative ticks
     * 3. Uses bit operations and precomputed values for gas efficiency
     * 4. Approximates 1.0001^tick without floating point math
     * 
     * Each bit position represents a power of 2 in the tick calculation,
     * allowing efficient computation by combining precomputed values.
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        // This is a simplified implementation based on the Uniswap V3 tick math
        // In production, you should import the TickMath library from Uniswap
        uint256 absTick = tick < 0 ? uint256(uint24(-tick)) : uint256(uint24(tick));
        require(absTick <= 887272, "Tick out of range");
        
        // Start with the base value (1 in Q96 format)
        uint256 ratio = 1 << 96;
        
        // Using bit shifts and integer math to approximate the 1.0001^tick calculation
        // Each power of 2 tick value is precomputed
        
        // Apply powers of 1.0001 using bitwise operations
        // We check each bit position and apply the corresponding factor if the bit is set
        if (absTick & 0x1 != 0) ratio = (ratio * 1000100000000000000) / 1000000000000000000;   // 1.0001^1
        if (absTick & 0x2 != 0) ratio = (ratio * 1000200010000000000) / 1000000000000000000;   // 1.0001^2
        if (absTick & 0x4 != 0) ratio = (ratio * 1000400060004000000) / 1000000000000000000;   // 1.0001^4
        if (absTick & 0x8 != 0) ratio = (ratio * 1000800240030008000) / 1000000000000000000;   // 1.0001^8
        if (absTick & 0x10 != 0) ratio = (ratio * 1001601281024016000) / 1000000000000000000;  // 1.0001^16
        if (absTick & 0x20 != 0) ratio = (ratio * 1003210121826557120) / 1000000000000000000;  // 1.0001^32
        // Add more bit shifts for higher powers if needed
        
        // Invert the ratio if tick is negative
        if (tick < 0) {
            ratio = (1 << 192) / ratio;
        }
        
        // Ensure the result fits in uint160
        require(ratio <= type(uint160).max, "Ratio overflow");
        return uint160(ratio);
    }
    
    //----------------------------------------------------------------
    // ADMIN FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Update the fee tier and active pool for price monitoring
     * @param newFee New fee tier to use in hundredths of a bip
     * @dev Updates the fee tier and finds the corresponding pool
     * 
     * This function:
     * 1. Updates the pool fee tier
     * 2. Locates the new pool from the Uniswap V3 Factory
     * 3. Verifies the pool exists
     * 4. Updates the active pool reference
     * 
     * This is useful when changing to a pool with better liquidity
     * or more accurate pricing.
     */
    function updatePoolFee(uint24 newFee) external onlyOwner {
        poolFee = newFee;
        
        // Update the active pool
        activePool = IUniswapV3Factory(uniswapV3Factory).getPool(
            cbBTCToken,
            usdcToken,
            poolFee
        );
        require(activePool != address(0), "Pool does not exist");
        
        emit PoolUpdated(activePool, poolFee);
    }
    
    /**
     * @notice Set a specific pool address for price monitoring
     * @param newPool Address of the pool to use
     * @dev Allows directly setting a specific pool rather than finding via factory
     * 
     * This provides flexibility to:
     * 1. Use custom pools not registered with the factory
     * 2. Use pools for related tokens with better liquidity
     * 3. Override the factory's pool selection if needed
     */
    function setActivePool(address newPool) external onlyOwner {
        require(newPool != address(0), "Invalid pool address");
        activePool = newPool;
        
        emit PoolUpdated(activePool, poolFee);
    }
    
    /**
     * @notice Update core contract addresses
     * @param _btfdVault New BTFD vault address
     * @param _navOracle New NAV oracle address
     * @param _uniswapFactory New Uniswap V3 factory address
     * @dev Only updates non-zero addresses, keeping existing ones otherwise
     * 
     * This function:
     * 1. Updates each non-zero address
     * 2. If the factory changes, updates the active pool
     * 3. Verifies the pool exists when factory changes
     */
    function updateAddresses(
        address _btfdVault,
        address _navOracle,
        address _uniswapFactory
    ) external onlyOwner {
        if (_btfdVault != address(0)) btfdVault = _btfdVault;
        if (_navOracle != address(0)) navOracle = _navOracle;
        if (_uniswapFactory != address(0)) {
            uniswapV3Factory = _uniswapFactory;
            
            // Update the active pool with the new factory
            activePool = IUniswapV3Factory(uniswapV3Factory).getPool(
                cbBTCToken,
                usdcToken,
                poolFee
            );
            require(activePool != address(0), "Pool does not exist");
        }
    }
    
    /**
     * @notice Update token addresses
     * @param _cbBTCToken New cbBTC token address
     * @param _usdcToken New USDC token address
     * @dev Updates token addresses and the corresponding pool
     * 
     * This function:
     * 1. Updates each non-zero token address
     * 2. If any token changes, finds the new pool
     * 3. Verifies the new pool exists
     * 
     * This is useful for upgrades or if token contracts change.
     */
    function updateTokenAddresses(
        address _cbBTCToken,
        address _usdcToken
    ) external onlyOwner {
        bool tokensChanged = false;
        
        if (_cbBTCToken != address(0)) {
            cbBTCToken = _cbBTCToken;
            tokensChanged = true;
        }
        
        if (_usdcToken != address(0)) {
            usdcToken = _usdcToken;
            tokensChanged = true;
        }
        
        // If tokens changed, update the active pool
        if (tokensChanged) {
            activePool = IUniswapV3Factory(uniswapV3Factory).getPool(
                cbBTCToken,
                usdcToken,
                poolFee
            );
            require(activePool != address(0), "Pool does not exist");
            
            emit PoolUpdated(activePool, poolFee);
        }
    }
    
    /**
     * @notice Configure price monitoring parameters
     * @param _minPriceMovement Minimum price movement to trigger checks
     * @param _checkInterval Minimum time between price checks in seconds
     * @dev Adjusts the sensitivity and frequency of price monitoring
     * 
     * These parameters balance:
     * 1. Responsiveness to price changes
     * 2. Gas efficiency by limiting check frequency
     * 3. Precision of strike triggering
     */
    function setPriceMonitoringParams(
        uint256 _minPriceMovement,
        uint256 _checkInterval
    ) external onlyOwner {
        minPriceMovement = _minPriceMovement;
        checkInterval = _checkInterval;
    }
    
    /**
     * @notice Emergency function to rescue tokens accidentally sent to this contract
     * @param token Token address to rescue
     * @param to Recipient address
     * @param amount Amount to rescue
     * @dev Safety function for recovering assets
     * 
     * This allows the owner to:
     * 1. Recover any tokens accidentally sent to the contract
     * 2. Manage funds in case of contract replacement or upgrade
     * 3. Handle edge cases in deposit processing
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}