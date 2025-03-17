// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/interfaces/IERC20.sol";
import "@uniswap/v4-core/contracts/BaseHook.sol";

interface IComet {
    function supply(address asset, uint amount) external;
    function withdraw(address asset, uint amount) external;
}

/**
 * @title IdleAssetHook
 * @notice Deploys out-of-range liquidity to Compound for additional yield
 */
contract IdleAssetHook is BaseHook {
    // Treasury (Gnosis Safe)
    address public treasury;
    // Compound v3 Comet contract
    address public compoundComet;
    
    // Token addresses
    address public fbtcToken;
    address public usdeToken;
    
    // Minimum amount to deploy to Compound (to avoid dust amounts)
    uint256 public minDeploymentThreshold;
    
    event IdleAssetsDeployed(address token, uint256 amount);
    event IdleAssetsWithdrawn(address token, uint256 amount);
    
    constructor(
        IPoolManager _poolManager,
        address _treasury,
        address _compoundComet,
        address _fbtcToken,
        address _usdeToken,
        uint256 _minDeploymentThreshold
    ) BaseHook(_poolManager) {
        treasury = _treasury;
        compoundComet = _compoundComet;
        fbtcToken = _fbtcToken;
        usdeToken = _usdeToken;
        minDeploymentThreshold = _minDeploymentThreshold;
    }
    
    /**
     * @notice Called after liquidity position changes
     * @dev Checks if positions are out of range and deploys idle assets
     */
    function afterModifyPosition(
        address owner,
        address sender,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        uint256 poolId
    ) external override returns (bytes4) {
        // Only proceed if this is from our treasury or authorized address
        if (owner != treasury) {
            return BaseHook.afterModifyPosition.selector;
        }
        
        // Get current tick/price
        int24 currentTick = getCurrentTick(poolId);
        
        // Check if position is out of range
        if (currentTick < tickLower || currentTick > tickUpper) {
            // Calculate idle tokens in this position
            (uint256 token0Amount, uint256 token1Amount) = calculateIdleAmounts(owner, tickLower, tickUpper, poolId);
            
            // Handle FBTC if idle and above threshold
            if (token0Amount > minDeploymentThreshold && address(token0) == fbtcToken) {
                deployToCompound(fbtcToken, token0Amount);
            }
            
            // Handle USDe if idle and above threshold
            if (token1Amount > minDeploymentThreshold && address(token1) == usdeToken) {
                deployToCompound(usdeToken, token1Amount);
            }
        }
        
        return BaseHook.afterModifyPosition.selector;
    }
    
    /**
     * @notice Deploy token to Compound
     * @param token Token to deploy
     * @param amount Amount to deploy
     */
    function deployToCompound(address token, uint256 amount) internal {
        // First need to withdraw from pool to treasury
        // This is simplified, actual implementation would use poolManager
        
        // Approve Compound to take tokens from this contract
        IERC20(token).approve(compoundComet, amount);
        
        // Supply to Compound
        IComet(compoundComet).supply(token, amount);
        
        emit IdleAssetsDeployed(token, amount);
    }
    
    /**
     * @notice Calculate idle amounts in a position
     * @param owner Position owner
     * @param tickLower Lower tick of position
     * @param tickUpper Upper tick of position
     * @param poolId Pool identifier
     * @return amount0 Amount of token0 idle
     * @return amount1 Amount of token1 idle
     */
    function calculateIdleAmounts(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 poolId
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // In a real implementation, you would:
        // 1. Get position details from Uniswap
        // 2. Calculate how much is not being used based on current tick
        
        // Placeholder logic
        return (0, 0); // Replace with actual calculation
    }
    
    /**
     * @notice Get current tick from pool
     * @param poolId Pool identifier
     * @return tick Current tick
     */
    function getCurrentTick(uint256 poolId) internal view returns (int24) {
        // In a real implementation, you would get this from poolManager
        return 0; // Replace with actual implementation
    }
    
    /**
     * @notice Withdraw assets from Compound when needed
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawFromCompound(address token, uint256 amount) external {
        // Only treasury can call this
        require(msg.sender == treasury, "Only treasury can withdraw");
        
        // Withdraw from Compound
        IComet(compoundComet).withdraw(token, amount);
        
        // Transfer to treasury
        IERC20(token).transfer(treasury, amount);
        
        emit IdleAssetsWithdrawn(token, amount);
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