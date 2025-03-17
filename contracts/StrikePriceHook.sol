// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/interfaces/IERC20.sol";
import "@uniswap/v4-core/contracts/BaseHook.sol";

interface IGnosisSafe {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool);
}

interface IMolochDAO {
    function mintShares(address to, uint256 amount) external;
}

interface INAVOracle {
    function calculateSharesForDeposit(uint256 fbtcAmount) external view returns (uint256);
}

/**
 * @title StrikePriceHook
 * @notice Uniswap V4 hook that monitors price and executes conversions when strike prices are hit
 */
contract StrikePriceHook is BaseHook {
    // Treasury (Gnosis Safe)
    address public treasury;
    // NAV Oracle
    address public navOracle;
    // MolochDAO
    address public molochDAO;
    
    // Token addresses
    address public fbtcToken;
    address public usdeToken;
    
    // Maps user addresses to their strike prices (in USDe per FBTC)
    mapping(address => uint256) public strikePoints;
    // Maps user addresses to their USDe deposits waiting for strike
    mapping(address => uint256) public userDeposits;
    
    // Minimum price movement to consider as a trigger (prevents dust triggers)
    uint256 public minPriceMovement;
    
    event StrikePointSet(address indexed user, uint256 strikePrice);
    event StrikeHit(address indexed user, uint256 strikePrice, uint256 convertedAmount, uint256 sharesIssued);
    
    constructor(
        IPoolManager _poolManager,
        address _treasury,
        address _navOracle,
        address _molochDAO,
        address _fbtcToken,
        address _usdeToken
    ) BaseHook(_poolManager) {
        treasury = _treasury;
        navOracle = _navOracle;
        molochDAO = _molochDAO;
        fbtcToken = _fbtcToken;
        usdeToken = _usdeToken;
        minPriceMovement = 1e15; // 0.1% by default
    }
    
    /**
     * @notice Sets a strike price for the caller
     * @param strikePrice The price at which USDe should convert to FBTC
     */
    function setStrikePoint(uint256 strikePrice) external {
        require(strikePrice > 0, "Strike price must be greater than 0");
        strikePoints[msg.sender] = strikePrice;
        emit StrikePointSet(msg.sender, strikePrice);
    }
    
    /**
     * @notice Deposit USDe waiting for strike price to hit
     * @param amount Amount of USDe to deposit
     */
    function depositUSDe(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(strikePoints[msg.sender] > 0, "Strike point must be set first");
        
        // Transfer USDe from user to this contract
        require(IERC20(usdeToken).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Update user deposit
        userDeposits[msg.sender] += amount;
    }
    
    /**
     * @notice Called after a swap occurs in the pool
     * @dev Checks if any user's strike price has been hit
     */
    function afterSwap(
        address sender,
        address recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        int24 tick,
        uint24 poolFee
    ) external override returns (bytes4) {
        // Calculate current price (USDe per FBTC)
        uint256 currentPrice = calculatePriceFromSqrtPrice(sqrtPriceX96);
        
        // Check all users with deposits
        // Note: In production, this would need optimization to avoid gas limits
        address[] memory usersToProcess = getUsersWithDeposits();
        
        for (uint i = 0; i < usersToProcess.length; i++) {
            address user = usersToProcess[i];
            uint256 strikePrice = strikePoints[user];
            uint256 depositAmount = userDeposits[user];
            
            // If user has a strike price and deposit, and price is at or below strike
            if (strikePrice > 0 && depositAmount > 0 && currentPrice <= strikePrice) {
                // Execute the conversion
                executeConversion(user, depositAmount, currentPrice);
            }
        }
        
        return BaseHook.afterSwap.selector;
    }
    
    /**
     * @notice Executes conversion from USDe to FBTC and deposits to DAO
     * @param user User address
     * @param usdeAmount Amount of USDe to convert
     * @param currentPrice Current FBTC price
     */
    function executeConversion(address user, uint256 usdeAmount, uint256 currentPrice) internal {
        // Calculate FBTC amount based on current price
        uint256 fbtcAmount = (usdeAmount * 1e18) / currentPrice;
        
        // Reset user deposit
        userDeposits[user] = 0;
        
        // Swap USDe to FBTC using Uniswap
        // Note: This is simplified, actual swap would use poolManager.swap
        // Approve, then execute swap...
        
        // Transfer FBTC to treasury
        // For now, we'll simulate this:
        // IERC20(fbtcToken).transfer(treasury, fbtcAmount);
        
        // Calculate shares based on NAV
        uint256 sharesToMint = INAVOracle(navOracle).calculateSharesForDeposit(fbtcAmount);
        
        // Mint DAO shares to user
        IMolochDAO(molochDAO).mintShares(user, sharesToMint);
        
        emit StrikeHit(user, strikePoints[user], fbtcAmount, sharesToMint);
    }
    
    /**
     * @notice Calculate price from sqrtPriceX96
     * @param sqrtPriceX96 The sqrt price from Uniswap
     * @return price The price of FBTC in USDe
     */
    function calculatePriceFromSqrtPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // Convert sqrtPriceX96 to price
        // This is a simplified calculation, actual implementation would depend on token decimals
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 / (2**192);
        return price;
    }
    
    /**
     * @notice Get list of users with active deposits
     * @return users Array of user addresses
     */
    function getUsersWithDeposits() internal view returns (address[] memory) {
        // This is a simplified placeholder
        // In production, you'd maintain a mapping or array of active users
        // to avoid having to iterate through all possible addresses
        
        // Return placeholder for now
        address[] memory placeholder = new address[](1);
        placeholder[0] = address(0); // This would be replaced with actual logic
        return placeholder;
    }
    
    // Hook interface implementations
    function beforeInitialize(address, address, uint160, int24) external pure override returns (bytes4) {
        return BaseHook.beforeInitialize.selector;
    }
    
    function afterInitialize(address, address, uint160, int24) external pure override returns (bytes4) {
        return BaseHook.afterInitialize.selector;
    }
    
    function beforeModifyPosition(address, address, int24, int24, int128) external pure override returns (bytes4) {
        return BaseHook.beforeModifyPosition.selector;
    }
    
    function afterModifyPosition(address, address, int24, int24, int128) external pure override returns (bytes4) {
        return BaseHook.afterModifyPosition.selector;
    }
    
    function beforeSwap(address, address, int256, int256) external pure override returns (bytes4) {
        return BaseHook.beforeSwap.selector;
    }
    
    function beforeDonate(address, int256, int256) external pure override returns (bytes4) {
        return BaseHook.beforeDonate.selector;
    }
    
    function afterDonate(address, int256, int256) external pure override returns (bytes4) {
        return BaseHook.afterDonate.selector;
    }
}