// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title StrikePriceHook - Cooperative Leverage Trading Mechanism
 * @notice Enables automated entry into a collective cbBTC position when target prices are hit
 * 
 * This is a cooperative system where:
 * 1. Users set individual strike prices for automated entry
 * 2. Later entrants at lower prices naturally improve the vault's overall position
 * 3. All participants benefit from increased collateral depth and improved NAV
 * 4. The 4626 vault ensures fair share distribution based on contribution value
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Uniswap V3 interfaces
interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
    );
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

// External contract interfaces
interface IBTFD {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function depositUSDCPending(uint256 usdcAmount) external;
    function setStrikePoint(uint256 strikePrice) external;
    function manuallyTriggerStrike(address user) external;
}

interface INAVOracle {
    function getCbBTCPrice() external view returns (uint256);
}

/**
 * @title StrikePriceHook
 * @notice Monitors Uniswap V3 prices and executes conversions when strike prices are hit
 */
contract StrikePriceHook is ReentrancyGuard, Ownable {
    //----------------------------------------------------------------
    // STATE VARIABLES
    //----------------------------------------------------------------
    
    // System contracts
    address public btfdVault;              // BTFD vault that holds assets
    address public navOracle;              // Provides pricing information
    
    // Uniswap V3 contracts
    address public uniswapV3Factory;       // Factory for creating/finding pools
    address public activePool;             // Currently active pool for price monitoring
    uint24 public poolFee;                 // Fee tier for the monitored pool
    
    // Token addresses
    address public cbBTCToken;             // cbBTC token address
    address public usdcToken;              // USDC token address
    
    // User data
    mapping(address => uint256) public userStrikePoints;    // User's target prices
    mapping(address => uint256) public userDeposits;        // User's USDC deposits
    
    // User registry - to avoid having to iterate all addresses
    mapping(address => bool) public hasDeposit;
    address[] public depositUsers;
    
    // Price monitoring
    uint256 public minPriceMovement;       // Minimum price movement to consider as a trigger
    uint256 public checkInterval;          // Minimum time between price checks (seconds)
    uint256 public lastCheckTime;          // Timestamp of last price check
    
    // Events
    event StrikePointSet(address indexed user, uint256 strikePrice);
    event StrikeHit(address indexed user, uint256 strikePrice, uint256 convertedAmount);
    event UserDeposited(address indexed user, uint256 amount);
    event PoolUpdated(address indexed pool, uint24 fee);
    event PriceChecked(uint256 timestamp, uint256 price);
    
    //----------------------------------------------------------------
    // CONSTRUCTOR & SETUP
    //----------------------------------------------------------------
    
    /**
     * @notice Sets up the contract with core system addresses
     * @param _btfdVault BTFD vault contract address
     * @param _navOracle NAV calculator contract address
     * @param _uniswapFactory Uniswap V3 factory address
     * @param _cbBTCToken cbBTC token address
     * @param _usdcToken USDC token address
     * @param _initialPoolFee Initial fee tier for the price monitoring pool (e.g., 3000 for 0.3%)
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
        
        minPriceMovement = 1e15; // 0.1% by default
        checkInterval = 5 minutes;
        lastCheckTime = block.timestamp;
    }
    
    //----------------------------------------------------------------
    // USER INTERACTION FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Sets a strike price for the caller
     * @param strikePrice The price at which USDC should convert to cbBTC
     * @dev Users must set their strike price before depositing
     */
    function setStrikePoint(uint256 strikePrice) external {
        require(strikePrice > 0, "Strike price must be greater than 0");
        
        userStrikePoints[msg.sender] = strikePrice;
        
        // Also set the strike price in the vault
        IBTFD(btfdVault).setStrikePoint(strikePrice);
        
        emit StrikePointSet(msg.sender, strikePrice);
    }
    
    /**
     * @notice Deposit USDC waiting for strike price to hit
     * @param amount Amount of USDC to deposit
     * @dev User must have already set a strike price
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
        
        // Check if strike price is already hit
        uint256 currentPrice = getCurrentPrice();
        if (currentPrice <= userStrikePoints[msg.sender]) {
            _triggerStrike(msg.sender, currentPrice);
        }
    }
    
    /**
     * @notice Check and trigger strikes based on current price
     * @dev Can be called by keepers or other external systems
     */
    function checkAndTriggerStrikes() external {
        // Rate limit checks to avoid spamming
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
                
                // User processed, adjust tracking
                i--; // Adjust index after removal
            }
        }
    }
    
    /**
     * @notice Get the current price from Uniswap V3
     * @return The current price of cbBTC in USDC
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
     * @return The TWAP of cbBTC in USDC over the period
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
            int24 avgTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(period)));
            
            // Convert tick to price
            uint160 sqrtPriceX96 = getSqrtRatioAtTick(avgTick);
            return calculatePriceFromSqrtPrice(sqrtPriceX96);
        } catch {
            // If observe fails, return current price
            return getCurrentPrice();
        }
    }
    
    //----------------------------------------------------------------
    // INTERNAL FUNCTIONS
    //----------------------------------------------------------------
    
    /**
     * @notice Trigger a strike conversion for a user
     * @param user Address of the user
     * @param currentPrice Current price of cbBTC
     */
    function _triggerStrike(address user, uint256 currentPrice) internal {
        uint256 depositAmount = userDeposits[user];
        if (depositAmount == 0) return;
        
        // Reset user deposit first to prevent reentrancy
        userDeposits[user] = 0;
        
        // Calculate theoretical cbBTC amount based on current price
        uint256 cbBTCAmount = (depositAmount * 1e18) / currentPrice;
        
        // Trigger the conversion via the vault
        IBTFD(btfdVault).manuallyTriggerStrike(user);
        
        // Remove user from tracking
        hasDeposit[user] = false;
        for (uint i = 0; i < depositUsers.length; i++) {
            if (depositUsers[i] == user) {
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
        if (absTick & 0x1 != 0) ratio = (ratio * 1000100000000000000) / 1000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 1000200010000000000) / 1000000000000000000;
        if (absTick & 0x4 != 0) ratio = (ratio * 1000400060004000000) / 1000000000000000000;
        if (absTick & 0x8 != 0) ratio = (ratio * 1000800240030008000) / 1000000000000000000;
        if (absTick & 0x10 != 0) ratio = (ratio * 1001601281024016000) / 1000000000000000000;
        if (absTick & 0x20 != 0) ratio = (ratio * 1003210121826557120) / 1000000000000000000;
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
     * @param newFee New fee tier to use
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
     */
    function setActivePool(address newPool) external onlyOwner {
        require(newPool != address(0), "Invalid pool address");
        activePool = newPool;
        
        emit PoolUpdated(activePool, poolFee);
    }
    
    /**
     * @notice Update contract addresses
     * @param _btfdVault New BTFD vault address
     * @param _navOracle New NAV oracle address
     * @param _uniswapFactory New Uniswap V3 factory address
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
     * @notice Set price monitoring parameters
     * @param _minPriceMovement Minimum price movement to trigger checks
     * @param _checkInterval Minimum time between price checks
     */
    function setPriceMonitoringParams(
        uint256 _minPriceMovement,
        uint256 _checkInterval
    ) external onlyOwner {
        minPriceMovement = _minPriceMovement;
        checkInterval = _checkInterval;
    }
    
    /**
     * @notice Rescue tokens accidentally sent to this contract
     * @param token Token to rescue
     * @param to Address to send tokens to
     * @param amount Amount to rescue
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}