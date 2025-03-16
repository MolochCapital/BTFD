# BTFD - Complete Roadmap for Solo Development on Mantle

## High-Level Overview
You're building a cooperative DCA + leverage system where users set ETH price "strike points." When ETH hits their price, their position converts to 100% ETH and enters a DAO. This ETH is used as collateral on Compound to borrow USDC to buy more ETH, creating leveraged upside exposure. The system generates yield from LP fees and lending idle USDC. Users can exit with their proportional share of assets. A 10% performance fee on profits goes to locked BAAL-ETH LP providers.

## Development Roadmap

### Stage 1: Core Contracts
1. **BAAL Token Contract**
   - Create basic ERC20 with fixed supply
   - Add team vesting with 4-year schedule
   - Deploy to Mantle testnet

2. **ETH/USDC Pool Setup**
   - Deploy Uniswap V4 pool contract
   - Configure fee tier (0.3% recommended)
   - Test basic swap functionality

3. **Moloch DAO Framework**
   - Deploy Moloch v3 contracts
   - Set rage quit parameters
   - Test share issuance and redemption

### Stage 2: Position Management
4. **Strike Price Hook**
   - Create Uniswap V4 hook that monitors ETH price
   - Add function to detect when positions hit strike prices
   - Test with manual price manipulation

5. **Position Converter**
   - Function to convert USDC to ETH when strike hits
   - Logic to withdraw ETH from pool
   - Test full conversion process

6. **DAO Deposit Handler**
   - Function to deposit converted ETH to DAO
   - Issue proportional DAO shares
   - Record entry price for performance fee calculation

### Stage 3: Leverage System
7. **Compound Integration**
   - Connect to Compound on Mantle
   - Create deposit function for DAO ETH
   - Test supply/withdraw functionality

8. **Leverage Manager**
   - Add USDC borrowing function
   - Create ETH purchase with borrowed USDC
   - Set safety parameters (max LTV 65%)

9. **NAV Calculator**
   - Function to calculate total assets (ETH + borrowed ETH)
   - Function to calculate total debt (USDC borrowed)
   - Calculate equity per share

### Stage 4: Yield Optimization
10. **LP Fee Collector**
    - Route Uniswap trading fees to DAO
    - Track fee accumulation
    - Test with simulated trades

11. **USDC Yield Manager**
    - Deposit inactive USDC to Compound
    - Harvest interest periodically
    - Add to DAO treasury

12. **Collateral Booster**
    - Function to add yield to ETH collateral
    - Recalculate leverage ratios
    - Test with simulated yield

### Stage 5: Exit Mechanics
13. **Proportional Unwinder**
    - Function to calculate member's share of assets/debt
    - Process to unwind appropriate amount of leverage
    - Test partial exit scenarios

14. **Performance Fee Calculator**
    - Compare exit ETH value to entry ETH value
    - Extract 10% of positive difference
    - Route fee to BAAL-ETH LP

15. **Rage Quit Handler**
    - Process member's exit with remaining assets
    - Burn appropriate DAO shares
    - Update NAV after exit

### Stage 6: LP Locking
16. **BAAL-ETH LP**
    - Create BAAL-ETH Uniswap pool
    - Set LP token parameters
    - Test liquidity provision

17. **LP Locker**
    - Create time-lock contract for LP tokens
    - Set minimum lock period (90 days recommended)
    - Test lock/unlock functionality

18. **Fee Distributor**
    - Distribute performance fees to locked LP
    - Weight by lock duration and amount
    - Test distribution with mock fees

### Stage 7: Integration & UI
19. **Contract Integration**
    - Connect all components with proper permissions
    - Create main entry point contract
    - Test full system flow

20. **Basic UI**
    - Position creation interface
    - NAV and position tracker
    - Exit request interface

21. **Final Testing**
    - Test full user journey
    - Simulate price movements
    - Verify fee calculations

### Stage 8: Launch
22. **Mantle Mainnet Deployment**
    - Deploy contract suite to mainnet
    - Seed initial liquidity
    - Set up monitoring

23. **Documentation**
    - Create user guide
    - Document contract addresses
    - Explain strategy mechanics

24. **Initial Operation**
    - Monitor first user positions
    - Track ETH price movements
    - Validate NAV calculations

## Development Tips
- **Build sequentially**: Complete each component before moving to the next
- **Test thoroughly**: Each component should work perfectly before integration
- **Use mock contracts**: Simulate external services during development
- **Start small**: Begin with minimal functionality, then expand
- **Monitor gas costs**: Optimize expensive operations for Mantle
- **Keep security first**: Double-check access controls and economic security

This plan breaks down every step needed to build your cooperative hedge fund solo, with each component addressing a specific part of the system you described.