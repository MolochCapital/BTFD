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

/**
 * @title FeeCollectorHook
 * @notice Routes LP fees from Uniswap pool to the treasury
 */
contract FeeCollectorHook is BaseHook {
    // Treasury (Gnosis Safe)
    address public treasury;
    // Minimum fee amount to collect (avoid dust transfers)
    uint256 public collectionThreshold;
    
    // Token addresses
    address public fbtcToken;
    address public usdeToken;
    
    event FeesCollected(address token, uint256 amount);
    
    constructor(
        IPoolManager _poolManager,
        address _treasury,
        address _fbtcToken,
        address _usdeToken,
        uint256 _collectionThreshold
    ) BaseHook(_poolManager) {
        treasury = _treasury;
        fbtcToken = _fbtcToken;
        usdeToken = _usdeToken;
        collectionThreshold = _collectionThreshold;
    }
    
    /**
     * @notice Called after fees are collected from the pool
     * @dev Redirects fees to treasury
     */
    function afterCollectFee(
        address owner, 
        address recipient, 
        uint256 amount0, 
        uint256 amount1
    ) external override returns (bytes4) {
        // Only intercept fees if recipient isn't already the treasury
        if (recipient != treasury) {
            // Handle FBTC fees
            if (amount0 > collectionThreshold) {
                // Transfer fees to treasury
                // Note: actual implementation would use poolManager methods
                // IERC20(fbtcToken).transfer(treasury, amount0);
                emit FeesCollected(fbtcToken, amount0);
            }
            
            // Handle USDe fees
            if (amount1 > collectionThreshold) {
                // Transfer fees to treasury
                // IERC20(usdeToken).transfer(treasury, amount1);
                emit FeesCollected(usdeToken, amount1);
            }
            
            // Notify treasury of fee collection if needed
            if (amount0 > 0 || amount1 > 0) {
                notifyTreasury(amount0, amount1);
            }
        }
        
        return BaseHook.afterCollectFee.selector;
    }
    
    /**
     * @notice Notify treasury of fee collection
     * @param amount0 Amount of token0 collected
     * @param amount1 Amount of token1 collected
     */
    function notifyTreasury(uint256 amount0, uint256 amount1) internal {
        // Create transaction data to call a method on treasury
        // This is a simplified example - actual implementation would depend on how
        // you want to handle fee accounting in the Gnosis Safe
        
        bytes memory data = abi.encodeWithSignature(
            "recordFeeCollection(address,uint256,address,uint256)",
            fbtcToken, 
            amount0,
            usdeToken,
            amount1
        );
        
        // Execute transaction on Gnosis Safe
        // In practice, you'd need to follow the Gnosis Safe execution flow
        // IGnosisSafe(treasury).execTransaction(
        //     treasury, // Target is treasury itself
        //     0, // No ETH value
        //     data,
        //     0 // Operation type (call)
        // );
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
    
    function afterSwap(address, address, int256, int256) external pure override returns (bytes4) {
        return BaseHook.afterSwap.selector;
    }
    
    function beforeDonate(address, int256, int256) external pure override returns (bytes4) {
        return BaseHook.beforeDonate.selector;
    }
    
    function afterDonate(address, int256, int256) external pure override returns (bytes4) {
        return BaseHook.afterDonate.selector;
    }
}