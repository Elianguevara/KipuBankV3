# 🏦 KipuBankV3

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://docs.soliditylang.org/)
[![Tests](https://img.shields.io/badge/Tests-51%2F51-brightgreen)](./test/)
[![Coverage](https://img.shields.io/badge/Coverage-95.07%25-brightgreen)](./test/)

> **DeFi Banking Protocol with Uniswap V2 Integration for Automatic Token Swaps**

**Verified Contract on Sepolia**: [`0xF7925F475D7EbF22Fc531C5E2830229C70567172`](https://sepolia.etherscan.io/address/0xF7925F475D7EbF22Fc531C5E2830229C70567172#code)

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [High-Level Improvements and Why](#high-level-improvements-and-why)
3. [Deployment Instructions](#deployment-instructions)
4. [Interaction Guide](#interaction-guide)
5. [Design Decisions and Trade-offs](#design-decisions-and-trade-offs)
6. [Threat Analysis Report](#threat-analysis-report)
7. [Test Coverage Report](#test-coverage-report)
8. [Roadmap to Production](#roadmap-to-production)

---

## 🎯 Overview

**KipuBankV3** is the evolution of KipuBankV2, transforming it into a production-ready DeFi application that integrates with Uniswap V2 for seamless token swaps. This contract fulfills all Module 4 requirements by enabling deposits of any ERC20 token with Uniswap V2 liquidity, automatically swapping them to USDC while respecting the bank capacity limit.

### Core Capabilities

The protocol automatically handles:
1. **Multi-token deposits**: ETH, USDC, and any ERC20 token with a USDC pair on Uniswap V2
2. **Automatic swaps**: Transparent token-to-USDC conversion via Uniswap V2 Router
3. **Unified accounting**: All balances tracked in USD-6 (USDC's 6 decimal format)
4. **Bank cap enforcement**: Total deposits never exceed the configured limit, even after swaps

### Key Features from V2 (Preserved)
- ✅ ETH and USDC deposits/withdrawals
- ✅ Role-based access control (Admin, Pauser, Treasurer)
- ✅ Emergency pause functionality
- ✅ Balance tracking per user

### New Features in V3
- ✅ **Generalized token deposits** with automatic swap to USDC
- ✅ **Uniswap V2 integration** for decentralized token exchange
- ✅ **Enhanced security**: ReentrancyGuard, counter overflow protection
- ✅ **Slippage protection**: Configurable tolerance (0.5% - 5%)
- ✅ **Oracle integration**: Chainlink price feeds for ETH/USD

---

## ✨ High-Level Improvements and Why

### 1. 🔄 Uniswap V2 Integration (Core Requirement)

**Why this improvement?**
In KipuBankV2, users could only deposit ETH or USDC directly. To deposit other tokens (DAI, LINK, WBTC), they had to:
1. Go to a DEX (e.g., Uniswap)
2. Manually swap their token to USDC
3. Return to KipuBank and deposit USDC

This created friction and poor UX.

**How V3 solves it:**
```solidity
function depositToken(address token, uint256 amountToken, uint256 minAmountOutUSDC)
    external whenNotPaused nonReentrant
{
    // 1. Transfer token from user
    IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
    
    // 2. Approve Uniswap Router
    IERC20(token).forceApprove(address(UNISWAP_ROUTER), amountToken);
    
    // 3. Execute swap: Token → USDC
    address[] memory path = new address[](2);
    path[0] = token;
    path[1] = address(USDC);
    
    uint256[] memory amounts = UNISWAP_ROUTER.swapExactTokensForTokens(
        amountToken, minAmountOutUSDC, path, address(this), block.timestamp + 300
    );
    
    // 4. Credit USDC to user's balance
    uint256 usdcReceived = amounts[amounts.length - 1];
    _processDeposit(usdcReceived);
}
```

**Benefits:**
- One-click deposits for any token
- Reduced transaction costs (1 tx instead of 2)
- Better UX for end users

### 2. 🛡️ Dynamic Bank Cap Enforcement

**Why this improvement?**
To prevent systemic risk, the protocol must limit total exposure. The bank cap ensures the contract doesn't hold more value than it can safely manage.

**Implementation:**
```solidity
function _processDeposit(uint256 amountUSD6) internal {
    uint256 currentTotal = s_totalUSD6;
    uint256 maxCap = s_bankCapUSD6;
    
    // Check AFTER swap to ensure actual received amount is validated
    if (currentTotal + amountUSD6 > maxCap) {
        revert CapExceeded(currentTotal + amountUSD6, maxCap);
    }
    
    unchecked {
        s_balances[msg.sender][address(USDC)] += amountUSD6;
        s_totalUSD6 += amountUSD6;
        s_depositCount++;
    }
}
```

**Why check after swap?**
The swap output can vary due to slippage. Checking after ensures we validate the actual USDC received, not the estimated amount.

### 3. 🔐 Enhanced Security Measures

**Why these improvements?**
Production DeFi requires multiple layers of security to protect user funds.

**Implemented protections:**
- **ReentrancyGuard**: Prevents reentrancy attacks on all deposit/withdrawal functions
- **Pausable**: Emergency stop mechanism for critical situations
- **AccessControl**: Granular permissions instead of single owner
- **SafeERC20**: Handles non-standard tokens (e.g., USDT that doesn't return bool)
- **Counter overflow protection**: Validates counters before incrementing to prevent overflow
- **Oracle validation**: Checks for stale prices and compromised data

### 4. 📉 Slippage Protection

**Why this improvement?**
DEX swaps are subject to price slippage. Without protection, users could receive significantly less than expected.

**Implementation:**
- Users can specify `minAmountOut` when depositing tokens
- Contract calculates a default minimum based on configurable slippage (default 1%)
- The stricter of the two is enforced
- Admin can adjust default slippage between 0.5% - 5%

---

## 🚀 Deployment Instructions

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Sepolia testnet ETH for gas
- Etherscan API key for verification

### Environment Setup

Create a `.env` file in the project root:
```bash
SEPOLIA_RPC_URL=your_sepolia_rpc_url
PRIVATE_KEY=your_private_key
ETHERSCAN_API_KEY=your_etherscan_api_key
```

### Deployment Steps

1. **Install dependencies:**
```bash
forge install
```

2. **Compile contracts:**
```bash
forge build
```

3. **Run tests:**
```bash
forge test
```

4. **Deploy to Sepolia:**
```bash
source .env
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

5. **Verify contract (if auto-verification fails):**
```bash
forge verify-contract \
  --chain-id 11155111 \
  --compiler-version v0.8.26+commit.8a97fa7a \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,uint256,uint256,uint256)" YOUR_ADMIN USDC_ADDRESS ORACLE_ADDRESS ROUTER_ADDRESS BANK_CAP WITHDRAWAL_THRESHOLD SLIPPAGE) \
  CONTRACT_ADDRESS \
  src/KipuBankV3.sol:KipuBankV3
```

### Current Deployment

- **Network**: Sepolia Testnet
- **Contract Address**: `0xF7925F475D7EbF22Fc531C5E2830229C70567172`
- **Etherscan**: [Verified ✅](https://sepolia.etherscan.io/address/0xF7925F475D7EbF22Fc531C5E2830229C70567172#code)
- **Deployer**: `0x1F3cf3D173E3eb50CaCA1B428515E3355f420004`

---

## 🔧 Interaction Guide

### Option A: Etherscan Web Interface

**For Auditors and Frontend Developers:**

1. **Navigate to Contract:**
   - Go to [Verified Contract](https://sepolia.etherscan.io/address/0xF7925F475D7EbF22Fc531C5E2830229C70567172#code)

2. **Read Functions (No wallet needed):**
   - Click "Read Contract" tab
   - `getBalanceUSD6(address user)`: Check user's balance
   - `getETHPrice()`: Get current ETH/USD price from oracle
   - `VERSION()`: Get contract version

3. **Write Functions (Requires wallet):**
   - Click "Write Contract" tab
   - Connect MetaMask to Sepolia
   - `depositETH()`: Deposit ETH (specify amount in payableAmount field)
   - `depositUSDC(uint256 amount)`: Deposit USDC directly
   - `depositToken(address token, uint256 amount, uint256 minOut)`: Deposit any ERC20
   - `withdrawUSDC(uint256 amount)`: Withdraw USDC
   - `withdrawETH(uint256 usd6Amount)`: Withdraw as ETH

### Option B: Foundry CLI (For Developers)

**Setup:**
```bash
source .env
```

**Read Operations:**
```bash
# Check balance
cast call 0xF7925F475D7EbF22Fc531C5E2830229C70567172 \
  "getBalanceUSD6(address)(uint256)" \
  YOUR_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL

# Get ETH price
cast call 0xF7925F475D7EbF22Fc531C5E2830229C70567172 \
  "getETHPrice()(uint256,uint8)" \
  --rpc-url $SEPOLIA_RPC_URL
```

**Write Operations:**
```bash
# Deposit 0.01 ETH
cast send 0xF7925F475D7EbF22Fc531C5E2830229C70567172 \
  "depositETH()" \
  --value 0.01ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# Withdraw 10 USDC
cast send 0xF7925F475D7EbF22Fc531C5E2830229C70567172 \
  "withdrawUSDC(uint256)" \
  10000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## 🏗️ Design Decisions and Trade-offs

### 1. Unified Accounting in USDC (USD-6)

**Decision:** All balances are stored normalized to 6 decimals (USDC format).

**Advantages:**
- Simplifies internal logic and risk calculations
- Users always know their "dollar" value
- Easier to implement bank cap enforcement
- Consistent accounting regardless of deposit token

**Trade-offs:**
- Users lose exposure to original token price movements
- If a user deposits WBTC and BTC price increases, they don't benefit
- Conversion happens immediately, no option to hold original asset

**Why we chose this:**
For a banking protocol, stability and predictability are more important than speculative gains. Users seeking price exposure should use other DeFi protocols.

### 2. Synchronous Swaps on Deposit

**Decision:** Swaps execute immediately when users deposit tokens.

**Advantages:**
- Superior UX: one transaction instead of two
- Atomic operation: either everything succeeds or everything reverts
- No intermediate state where user has deposited but swap hasn't occurred

**Trade-offs:**
- Higher gas costs in the deposit transaction
- User pays for swap gas even if they would have preferred to swap separately
- Slippage risk is borne by the user

**Why we chose this:**
The UX improvement outweighs the gas cost. Advanced users who want to optimize gas can swap to USDC first and use `depositUSDC()`.

### 3. Uniswap V2 Instead of V3

**Decision:** Integrate with Uniswap V2 Router instead of V3.

**Advantages:**
- Simpler integration (no tick/range logic)
- More predictable gas costs
- Wider availability on testnets
- Well-tested and battle-hardened protocol

**Trade-offs:**
- Less capital efficient than V3
- Potentially worse prices for users
- Missing concentrated liquidity benefits

**Why we chose this:**
For a testnet deployment and educational project, simplicity and reliability are more important than capital efficiency. V3 integration can be added in a future version.

### 4. Role-Based Access Control

**Decision:** Use OpenZeppelin's AccessControl instead of simple Ownable.

**Advantages:**
- Granular permissions (Admin, Pauser, Treasurer)
- Multiple addresses can have the same role
- Easier to implement multisig or DAO governance later
- Follows principle of least privilege

**Trade-offs:**
- Slightly higher gas costs for role checks
- More complex to manage than single owner
- Requires careful role assignment

**Why we chose this:**
Security and flexibility justify the added complexity. Production DeFi requires separation of concerns.

---

## 🕵️ Threat Analysis Report

### Protocol Weaknesses Identified

#### 1. Single Oracle Dependency (Medium Risk)

**Issue:** The contract relies solely on Chainlink for ETH/USD price data.

**Impact:** If the Chainlink oracle:
- Fails or freezes → `getETHPrice()` reverts → ETH deposits fail
- Returns manipulated data → Incorrect ETH→USDC conversions

**Current Mitigations:**
- Oracle validation checks (stale price, negative price, incomplete round)
- 1-hour heartbeat tolerance
- Direct token deposits still work via Uniswap pricing

**Recommendation for Production:**
- Implement TWAP (Time-Weighted Average Price) as backup oracle
- Add circuit breakers for extreme price movements
- Consider multiple oracle sources (Chainlink + Band Protocol)

#### 2. Flash Loan Price Manipulation (Low Risk)

**Issue:** Although we use Chainlink (not Uniswap) for ETH pricing, Uniswap pool prices could still be manipulated for token swaps.

**Impact:** Attacker could:
1. Take flash loan
2. Manipulate Uniswap pool price
3. Deposit token at inflated price
4. Receive more USDC than deserved

**Current Mitigations:**
- ReentrancyGuard prevents reentrancy attacks
- Slippage protection limits maximum loss
- Bank cap limits total exposure

**Recommendation for Production:**
- Implement TWAP for token pricing
- Add minimum liquidity requirements
- Consider token whitelist

#### 3. Centralized Admin Control (High Risk)

**Issue:** `DEFAULT_ADMIN_ROLE` has full control to:
- Change bank cap
- Pause/unpause contract
- Modify slippage settings

**Impact:** Malicious or compromised admin could:
- Pause contract and lock user funds
- Set bank cap to 0, preventing withdrawals
- Set extreme slippage allowing value extraction

**Current Mitigations:**
- Role-based access (not single owner)
- Events emitted for all admin actions
- Code is open source and verified

**Recommendation for Production:**
- Implement TimelockController (24-48 hour delay)
- Use multisig wallet (3-of-5 or 5-of-9)
- Consider DAO governance for major changes

#### 4. Token Compatibility Issues (Medium Risk)

**Issue:** Not all ERC20 tokens behave the same:
- Fee-on-transfer tokens (e.g., SAFEMOON)
- Rebasing tokens (e.g., AMPL)
- Tokens with blacklists (e.g., USDC, USDT)

**Impact:** 
- Fee-on-transfer: Accounting mismatch (we credit more than received)
- Rebasing: Balance changes unexpectedly
- Blacklists: Funds could get stuck

**Current Mitigations:**
- SafeERC20 handles non-standard return values
- Try-catch on swaps prevents total failure

**Recommendation for Production:**
- Implement token whitelist
- Add balance checks before/after transfers
- Explicitly block known problematic tokens

### Missing Steps for Production Maturity

1. **Security Audit**
   - Engage professional audit firm (Trail of Bits, OpenZeppelin, etc.)
   - Bug bounty program on Immunefi
   - Formal verification of critical functions

2. **Oracle Improvements**
   - Implement TWAP for backup pricing
   - Add circuit breakers for extreme price movements
   - Multiple oracle sources with median calculation

3. **Governance Decentralization**
   - Deploy TimelockController
   - Implement multisig for admin role
   - Consider DAO governance token

4. **Token Safety**
   - Implement token whitelist
   - Add balance verification before/after transfers
   - Block fee-on-transfer and rebasing tokens

5. **Monitoring and Alerts**
   - Set up real-time monitoring (Tenderly, Defender)
   - Alert system for unusual activity
   - Automated pause triggers for anomalies

6. **Insurance**
   - Explore protocol insurance (Nexus Mutual, Unslashed)
   - Set aside treasury for potential exploits
   - Implement gradual rollout with increasing caps

---

## 🧪 Test Coverage Report

### Testing Methodology

The project uses **Foundry** for comprehensive testing with multiple approaches:

#### 1. Unit Tests
Isolated tests for individual functions:
- Constructor validation (7 tests)
- Deposit functions (ETH, USDC, Token) (8 tests)
- Withdrawal functions (ETH, USDC) (4 tests)
- Admin functions (pause, unpause, cap, slippage) (5 tests)
- Access control (4 tests)
- Oracle validation (3 tests)

#### 2. Integration Tests
Tests with mocks simulating real protocols:
- **MockV3Aggregator**: Simulates Chainlink oracle
- **MockUniswapRouter**: Simulates Uniswap V2 swaps
- **MockERC20**: Simulates various ERC20 tokens

#### 3. Fuzz Testing
Randomized inputs to find edge cases:
- `testFuzz_DepositUSDC(uint256)`: 256 runs
- `testFuzz_TotalNeverExceedsCap(uint256,uint256)`: 128 runs
- `testFuzz_WithdrawPartial(uint256,uint256)`: 256 runs

#### 4. Fork Testing
Tests against real Sepolia contracts:
- Validates integration with actual USDC contract
- Tests with real Uniswap V2 Router
- Verifies Chainlink oracle compatibility

### Coverage Results

**Overall Coverage: 95.07% lines, 100% functions** ✅

Detailed breakdown:
```
╭──────────────────────────────────────────────────────────────────────────────╮
│ File                             │ % Lines  │ % Statements │ % Branches │ % Funcs │
├──────────────────────────────────────────────────────────────────────────────┤
│ src/KipuBankV3.sol               │ 95.07%   │ 94.00%       │ 76.47%     │ 100.00% │
│ script/DeployKipuBankV3.s.sol    │ 0.00%    │ 0.00%        │ 100.00%    │ 0.00%   │
│ test/mocks/MockERC20.sol         │ 50.00%   │ 50.00%       │ 100.00%    │ 50.00%  │
│ test/mocks/MockUniswapRouter.sol │ 86.36%   │ 86.49%       │ 55.56%     │ 88.89%  │
│ test/mocks/MockV3Aggregator.sol  │ 73.08%   │ 83.33%       │ 100.00%    │ 50.00%  │
╰──────────────────────────────────────────────────────────────────────────────╯
```

**Note:** Deployment script (0% coverage) is excluded as it's not part of the production contract.

### Test Execution

Run all tests:
```bash
forge test
```

Run with verbosity:
```bash
forge test -vvv
```

Run specific test:
```bash
forge test --match-test test_DepositETH_SwapsToUSDC
```

Generate coverage report:
```bash
forge coverage
```

### Test Results

All 51 tests pass:
```
Ran 51 tests for test/KipuBankV3.t.sol:KipuBankV3Test
[PASS] testFuzz_DepositUSDC(uint256) (runs: 256, μ: 342168, ~: 342311)
[PASS] testFuzz_TotalNeverExceedsCap(uint256,uint256) (runs: 128, μ: 599036, ~: 599268)
[PASS] testFuzz_WithdrawPartial(uint256,uint256) (runs: 256, μ: 371958, ~: 372156)
[PASS] test_Admin_PauseAndUnpause() (gas: 30020)
[PASS] test_Admin_SetBankCapUSD6() (gas: 23426)
... (46 more tests)

Suite result: ok. 51 passed; 0 failed; 0 skipped
```

**Coverage exceeds 50% requirement by 45.07 percentage points** ✅

---

## 🛣️ Roadmap to Production

### Completed ✅
- [x] Smart Contract Development (V3)
- [x] Comprehensive Unit Tests (51 tests)
- [x] Fuzz Testing (640 randomized runs)
- [x] Integration Tests with Mocks
- [x] Fork Testing on Sepolia
- [x] Testnet Deployment (Sepolia)
- [x] Etherscan Verification
- [x] Documentation (NatSpec + README)
- [x] 95.07% Test Coverage

### In Progress 🔄
- [ ] Security Audit (pending funding)
- [ ] Gas Optimization Review
- [ ] Frontend Integration Testing

### Planned 📋
- [ ] TWAP Oracle Implementation
- [ ] Token Whitelist System
- [ ] TimelockController Deployment
- [ ] MultiSig Wallet Setup (3-of-5)
- [ ] Monitoring System (Tenderly/Defender)
- [ ] Bug Bounty Program (Immunefi)
- [ ] Mainnet Deployment
- [ ] Protocol Insurance (Nexus Mutual)

---

## 📚 Additional Resources

### For Auditors
- All code is documented with NatSpec comments
- Critical functions have detailed security notes
- Test suite demonstrates expected behavior
- Known limitations documented in Threat Analysis

### For Frontend Developers
- Contract ABI available on Etherscan
- All functions have clear input/output specifications
- Events emitted for all state changes
- Example interactions provided in this README

### For Users
- Interaction guide covers both web and CLI
- Clear explanation of deposit/withdrawal flow
- Risk disclosures in Threat Analysis section

---

## 📄 License

This project is licensed under the MIT License.

---

## 👤 Author

**Elian Guevara**
- Email: elian.guevara689@gmail.com
- GitHub: [Repository Link]

---

_Module 4 Final Project - 2025_
_Ethereum Developer Program - Blockchain Specialization_
