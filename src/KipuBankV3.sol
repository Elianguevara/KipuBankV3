// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*///////////////////////////
          IMPORTS
///////////////////////////*/
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title KipuBankV3
 * @author Elian Guevara
 * @notice DeFi Banking Protocol with Uniswap V2 integration for automatic token swaps to USDC.
 * @dev All assets are converted to and stored internally as USDC (USD-6 format).
 *      The contract implements OpenZeppelin's AccessControl for role-based permissions,
 *      Pausable for emergency stops, and ReentrancyGuard for protection against reentrancy attacks.
 *      
 *      Architecture:
 *      - Deposits: ETH and any ERC20 token → auto-swapped to USDC via Uniswap V2
 *      - Accounting: All balances tracked in USD-6 (USDC's 6 decimal format)
 *      - Withdrawals: Only in ETH (swapped from USDC) or direct USDC
 *      - Security: Multiple layers including counter overflow protection, oracle validation,
 *                  slippage controls, and capacity limits
 *      
 *      Key Features:
 *      - Multi-token deposits with automatic conversion to USDC
 *      - Chainlink price feeds for ETH/USD conversion
 *      - Configurable slippage tolerance (0.5% - 5%)
 *      - Bank capacity limits to control total exposure
 *      - Per-transaction withdrawal limits
 *      - Role-based access control (Admin, Pauser, Treasurer)
 *      - Emergency pause functionality
 *      - Counter overflow protection for all operations
 *      
 * @custom:security-contact elian.guevara689@gmail.com
 * @custom:deployed-to Sepolia Testnet: 0x68f19cfCE402C661F457e3fF77b1E056a5EC6dA8
 * @custom:etherscan https://sepolia.etherscan.io/address/0x68f19cfce402c661f457e3ff77b1e056a5ec6da8
 * @custom:version 3.0.1
 */
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*///////////////////////////
            ERRORS
    ///////////////////////////*/
    
    /**
     * @notice Thrown when an operation involves a zero amount, which is not allowed.
     * @dev This error prevents wasteful transactions and ensures meaningful operations.
     *      Applies to deposits, withdrawals, and administrative rescue operations.
     */
    error ZeroAmount();
    
    /**
     * @notice Thrown when a deposit would exceed the bank's maximum capacity limit.
     * @dev This error protects the protocol from over-exposure and maintains manageable risk levels.
     * @param requested The total amount that was attempted (current s_totalUSD6 + new deposit amount).
     * @param available The maximum capacity currently allowed by s_bankCapUSD6.
     */
    error CapExceeded(uint256 requested, uint256 available);
    
    /**
     * @notice Thrown when a user attempts to withdraw more than their available balance.
     * @dev This error enforces balance constraints and prevents overdrafts.
     * @param requested The withdrawal amount requested by the user in USD-6.
     * @param balance The user's actual available balance in USD-6.
     */
    error InsufficientBalance(uint256 requested, uint256 balance);
    
    /**
     * @notice Thrown when the Chainlink oracle returns invalid or compromised data.
     * @dev This error triggers when:
     *      - The price is zero or negative (p <= 0)
     *      - The answeredInRound is less than the roundId (indicating stale or incomplete round)
     *      This is a critical security check to prevent price manipulation attacks.
     */
    error OracleCompromised();
    
    /**
     * @notice Thrown when the oracle price data is outdated beyond acceptable limits.
     * @dev This error triggers when the time elapsed since the last oracle update (updatedAt)
     *      exceeds the ORACLE_HEARTBEAT constant (3600 seconds / 1 hour).
     *      Stale prices could lead to incorrect conversions and user losses.
     */
    error StalePrice();
    
    /**
     * @notice Thrown when a withdrawal amount exceeds the per-transaction limit.
     * @dev This error enforces the WITHDRAWAL_THRESHOLD_USD6 immutable parameter,
     *      which limits the maximum amount that can be withdrawn in a single transaction.
     *      This provides an additional layer of security against large unauthorized withdrawals.
     * @param requested The amount the user attempted to withdraw in USD-6.
     * @param limit The maximum allowed per-transaction withdrawal limit (WITHDRAWAL_THRESHOLD_USD6).
     */
    error WithdrawalLimitExceeded(uint256 requested, uint256 limit);
    
    /**
     * @notice Thrown when a native ETH transfer fails during execution.
     * @dev This error occurs when a low-level call to transfer ETH returns false.
     *      Primarily used in the rescue function when recovering stuck native ETH.
     */
    error ETHTransferFailed();
    
    /**
     * @notice Thrown when constructor parameters fail validation checks.
     * @dev This error triggers during deployment if any of the following conditions are met:
     *      - Any required address parameter is the zero address (admin, usdc, ethUsdFeed, uniswapRouter)
     *      - The bankCapUSD6 is zero
     *      - The withdrawalThresholdUSD6 is zero
     *      - The withdrawalThresholdUSD6 exceeds the bankCapUSD6
     *      This ensures the contract is deployed with valid, sensible configuration.
     */
    error InvalidParameters();
    
    /**
     * @notice Thrown when attempting to receive native ETH through an unauthorized method.
     * @dev The receive() function only accepts ETH from the Uniswap Router contract.
     *      Users must use the depositETH() function for deposits.
     *      This prevents accidental ETH transfers and maintains proper accounting.
     */
    error UseDepositETH();
    
    /**
     * @notice Thrown when a Uniswap swap operation fails.
     * @dev This error occurs when the Uniswap Router's swap functions revert.
     *      Common causes include:
     *      - Insufficient liquidity in the pool
     *      - Slippage tolerance exceeded
     *      - Invalid swap path
     *      - Expired deadline
     *      The error is caught via try-catch and re-thrown for clarity.
     */
    error SwapFailed();
    
    /**
     * @notice Thrown when slippage parameters are outside acceptable bounds.
     * @dev This error enforces that slippage values must be between:
     *      - MIN_SLIPPAGE_BPS (50 basis points = 0.5%)
     *      - MAX_SLIPPAGE_BPS (500 basis points = 5%)
     *      Values outside this range are considered either too restrictive (likely to fail)
     *      or too permissive (vulnerable to MEV attacks).
     */
    error InvalidSlippage();
    
    /**
     * @notice Thrown when attempting to deposit USDC via the depositToken function.
     * @dev USDC deposits must use the dedicated depositUSDC() function.
     *      The depositToken() function is reserved for other ERC20 tokens that require swapping.
     *      This separation improves gas efficiency and code clarity.
     */
    error UnsupportedToken();
    
    /**
     * @notice Thrown when an operation counter reaches its maximum safe value.
     * @dev This error prevents counter overflow by checking against MAX_COUNTER_VALUE
     *      before incrementing s_depositCount, s_withdrawCount, or s_swapCount.
     *      The maximum value is (type(uint256).max - 1) to provide a safety margin.
     */
    error CounterOverflow();

    /*///////////////////////////
        TYPE DECLARATIONS
    ///////////////////////////*/
    
    /**
     * @notice Enum to classify the type of operation for counter tracking and validation.
     * @dev Used in the validateCounter modifier to check the appropriate counter
     *      before allowing an operation to proceed.
     */
    enum CounterType {
        /// @notice Represents a deposit operation (increments s_depositCount).
        DEPOSIT,
        /// @notice Represents a withdrawal operation (increments s_withdrawCount).
        WITHDRAWAL,
        /// @notice Represents a swap operation via Uniswap (increments s_swapCount).
        SWAP
    }

    /*///////////////////////////
          STATE VARIABLES
    ///////////////////////////*/
    
    // ======== ROLES ========
    
    /**
     * @notice Role identifier for pausing and unpausing contract functions.
     * @dev Grants the ability to call pause() and unpause() functions.
     *      Typically assigned to security operators or admin for emergency responses.
     *      Calculated as: keccak256("PAUSER_ROLE")
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    /**
     * @notice Role identifier for the treasurer, enabling recovery of stuck funds.
     * @dev Grants the ability to call the rescue() function to recover:
     *      - Accidentally sent ERC20 tokens
     *      - Stuck native ETH
     *      Should be assigned to a trusted treasury address or multisig wallet.
     *      Calculated as: keccak256("TREASURER_ROLE")
     */
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    
    // ======== CONSTANTS ========
    
    /**
     * @notice Maximum allowed value for operation counters to prevent overflow.
     * @dev Set to (type(uint256).max - 1) to provide a safety margin.
     *      Made public to allow verification in tests and external monitoring.
     *      Once a counter reaches this value, the corresponding operation type will revert.
     *      Value: 115792089237316195423570985008687907853269984665640564039457584007913129639934
     */
    uint256 public constant MAX_COUNTER_VALUE = type(uint256).max - 1;
    
    /**
     * @notice Maximum acceptable age for Chainlink oracle data in seconds.
     * @dev Set to 3600 seconds (1 hour) based on Chainlink's typical ETH/USD update frequency.
     *      If the oracle's updatedAt timestamp is older than this value, the StalePrice error is thrown.
     *      This prevents using outdated prices that could lead to incorrect conversions.
     */
    uint32 public constant ORACLE_HEARTBEAT = 3600;
    
    /**
     * @notice The number of decimal places used by USDC and for internal accounting.
     * @dev USDC uses 6 decimals, unlike most ERC20 tokens which use 18.
     *      All balances in the contract are stored in USD-6 format (6 decimal places).
     *      Example: 1 USDC = 1,000,000 USD-6 units
     */
    uint8 public constant USD_DECIMALS = 6;
    
    /**
     * @notice Minimum acceptable slippage tolerance in Basis Points (BPS).
     * @dev Set to 50 BPS = 0.5%.
     *      Slippage values below this threshold are too restrictive and may cause
     *      legitimate swaps to fail due to normal market volatility.
     */
    uint256 public constant MIN_SLIPPAGE_BPS = 50;
    
    /**
     * @notice Maximum acceptable slippage tolerance in Basis Points (BPS).
     * @dev Set to 500 BPS = 5%.
     *      Slippage values above this threshold are too permissive and expose users
     *      to significant MEV (Miner Extractable Value) attacks and sandwich attacks.
     */
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    
    /**
     * @notice Denominator used for Basis Point calculations.
     * @dev 1 BPS = 1/10000 = 0.01%.
     *      Used in slippage calculations: (amount * bps) / BPS_DENOMINATOR
     *      Example: 100 BPS = 100/10000 = 1%
     */
    uint256 private constant BPS_DENOMINATOR = 10000;
    
    /**
     * @notice Current version string of the contract.
     * @dev Follows Semantic Versioning 2.0.0 (semver.org).
     *      Format: MAJOR.MINOR.PATCH
     *      - MAJOR: Incompatible API changes
     *      - MINOR: Backward-compatible functionality additions
     *      - PATCH: Backward-compatible bug fixes
     */
    string public constant VERSION = "3.0.1";
    
    // ======== IMMUTABLES ========
    
    /**
     * @notice The USDC token contract used as the internal reserve currency.
     * @dev All deposits are converted to USDC and all balances are tracked in USD-6.
     *      Set during construction and cannot be changed.
     *      On Sepolia testnet: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
     *      On Ethereum mainnet: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
     */
    IERC20 public immutable USDC;
    
    /**
     * @notice The Chainlink Aggregator interface for the ETH/USD price feed.
     * @dev Used to convert ETH amounts to USD equivalents during deposits and withdrawals.
     *      Provides real-time, tamper-resistant price data with built-in security checks.
     *      Set during construction and cannot be changed.
     *      On Sepolia testnet: 0x694AA1769357215DE4FAC081bf1f309aDC325306
     *      On Ethereum mainnet: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
     */
    AggregatorV3Interface public immutable ETH_USD_FEED;
    
    /**
     * @notice The number of decimal places reported by the Chainlink price feed.
     * @dev Cached during construction for gas optimization.
     *      Typically 8 decimals for ETH/USD feeds (e.g., $2000.00000000).
     *      Used in price conversion calculations to ensure correct scaling.
     */
    uint8 public immutable FEED_DECIMALS;
    
    /**
     * @notice The Uniswap V2 Router contract interface for executing token swaps.
     * @dev Used for:
     *      - Swapping deposited tokens (ETH or ERC20) to USDC
     *      - Swapping USDC back to ETH for withdrawals
     *      Set during construction and cannot be changed.
     *      On Sepolia testnet: 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008
     *      On Ethereum mainnet: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
     */
    IUniswapV2Router02 public immutable UNISWAP_ROUTER;
    
    /**
     * @notice The maximum withdrawal amount allowed per transaction, denominated in USD-6.
     * @dev Set during construction and cannot be changed.
     *      Provides an additional security layer against large unauthorized withdrawals.
     *      Example: 10,000 * 1e6 = 10,000 USD limit per withdrawal
     *      This is checked in the validateWithdrawal modifier before any withdrawal.
     */
    uint256 public immutable WITHDRAWAL_THRESHOLD_USD6;

    // ======== STORAGE ========
    
    /**
     * @notice Mapping of user balances in USD-6 format.
     * @dev Nested mapping structure: user address => token address => balance in USD-6.
     *      In practice, only the USDC address key is used since all balances are stored in USDC.
     *      Example: s_balances[userAddress][address(USDC)] = 1000000 (= 1 USD)
     *      
     *      The nested mapping structure allows for future extensibility while maintaining
     *      current simplicity (single currency accounting).
     */
    mapping(address user => mapping(address token => uint256 usd6)) private s_balances;
    
    /**
     * @notice The total outstanding balance across all users, denominated in USD-6.
     * @dev Sum of all user balances in the system.
     *      Updated on every deposit (increases) and withdrawal (decreases).
     *      Must never exceed s_bankCapUSD6.
     *      Used for:
     *      - Capacity limit enforcement
     *      - Protocol health monitoring
     *      - Total Value Locked (TVL) calculation
     */
    uint256 public s_totalUSD6;
    
    /**
     * @notice The maximum total capacity (cap) of the bank in USD-6.
     * @dev Configurable by admin via setBankCapUSD6().
     *      Enforced on every deposit to limit total protocol exposure.
     *      Example: 1,000,000 * 1e6 = 1 million USD capacity
     *      
     *      Purpose:
     *      - Risk management: Limits total funds at risk
     *      - Phased rollout: Can start with lower cap and increase gradually
     *      - Emergency brake: Can be reduced if issues detected
     */
    uint256 public s_bankCapUSD6;
    
    /**
     * @notice The default slippage tolerance applied to swaps, measured in Basis Points (BPS).
     * @dev Configurable by admin via setDefaultSlippage().
     *      Must be between MIN_SLIPPAGE_BPS (50) and MAX_SLIPPAGE_BPS (500).
     *      Example: 100 BPS = 1% slippage tolerance
     *      
     *      Usage:
     *      - Applied when calculating minimum output amounts for Uniswap swaps
     *      - Users can provide stricter limits in depositToken() via minAmountOutUSDC parameter
     *      - The stricter of the two (user's or protocol's) is used
     *      
     *      Calculation: minOut = expectedOut * (10000 - s_defaultSlippageBps) / 10000
     */
    uint256 public s_defaultSlippageBps;
    
    /**
     * @notice Counter for successful deposit operations.
     * @dev Incremented on every successful deposit (ETH, USDC, or token).
     *      Protected against overflow by validateCounter modifier.
     *      Used for:
     *      - Operation tracking and analytics
     *      - Event correlation
     *      - Counter overflow protection
     */
    uint256 public s_depositCount;
    
    /**
     * @notice Counter for successful withdrawal operations.
     * @dev Incremented on every successful withdrawal (ETH or USDC).
     *      Protected against overflow by validateCounter modifier.
     *      Used for:
     *      - Operation tracking and analytics
     *      - Event correlation
     *      - Counter overflow protection
     */
    uint256 public s_withdrawCount;
    
    /**
     * @notice Counter for swap operations initiated by the contract via Uniswap.
     * @dev Incremented when depositETH() or depositToken() triggers a swap.
     *      Protected against overflow by validateCounter modifier.
     *      Used for:
     *      - Swap analytics and monitoring
     *      - Gas cost tracking
     *      - Event correlation
     *      Note: Direct USDC deposits do not increment this counter.
     */
    uint256 public s_swapCount;

    /*///////////////////////////
            EVENTS
    ///////////////////////////*/
    
    /**
     * @notice Emitted when a deposit is successfully registered and credited to the user.
     * @dev Emitted after balance updates and counter increments.
     *      For swap-based deposits (ETH or tokens), this is emitted after the swap succeeds.
     * @param user The address of the user who made the deposit.
     * @param tokenIn The address of the token deposited.
     *                - address(0) for native ETH deposits
     *                - address(USDC) for direct USDC deposits  
     *                - Other ERC20 address for token deposits that were swapped to USDC
     * @param amountIn The native amount of the token deposited (not normalized to USD-6).
     *                 - For ETH: amount in wei (18 decimals)
     *                 - For USDC: amount in USD-6 (6 decimals)
     *                 - For other tokens: amount in token's native decimals
     * @param creditedUSD6 The amount of USD-6 credited to the user's balance after swap (if applicable).
     *                     This is the actual USDC amount received and credited.
     */
    event Deposit(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 creditedUSD6
    );

    /**
     * @notice Emitted when a withdrawal is successfully processed and sent to the user.
     * @dev Emitted after balance updates, counter increments, and token transfers.
     *      For ETH withdrawals, emitted after the USDC→ETH swap succeeds.
     * @param user The address of the user who made the withdrawal.
     * @param tokenOut The address of the token withdrawn.
     *                 - address(0) for native ETH withdrawals
     *                 - address(USDC) for direct USDC withdrawals
     * @param debitedUSD6 The amount of USD-6 debited from the user's internal balance.
     * @param amountTokenOut The native amount of the token sent to the user.
     *                       - For ETH: amount in wei (18 decimals)
     *                       - For USDC: amount in USD-6 (6 decimals)
     */
    event Withdrawal(
        address indexed user,
        address indexed tokenOut,
        uint256 debitedUSD6,
        uint256 amountTokenOut
    );

    /**
     * @notice Emitted when the admin updates the bank's maximum capacity.
     * @dev Only emitted by setBankCapUSD6() function.
     * @param newCapUSD6 The new maximum capacity limit in USD-6.
     */
    event BankCapUpdated(uint256 newCapUSD6);
    
    /**
     * @notice Emitted when the admin updates the default slippage tolerance.
     * @dev Only emitted by setDefaultSlippage() function.
     * @param newSlippageBps The new slippage tolerance value in Basis Points (BPS).
     */
    event SlippageUpdated(uint256 newSlippageBps);
    
    /*///////////////////////////
            MODIFIERS
    ///////////////////////////*/
    
    /**
     * @notice Validates withdrawal parameters before executing the withdrawal.
     * @dev Performs three critical checks:
     *      1. Amount is non-zero
     *      2. Amount does not exceed per-transaction limit (WITHDRAWAL_THRESHOLD_USD6)
     *      3. User has sufficient balance
     *      
     *      Note: Balance check uses s_balances[msg.sender][address(USDC)] since all
     *      balances are stored under the USDC key in the V3 architecture.
     * @param usd6Amount The amount in USD-6 to withdraw.
     */
    modifier validateWithdrawal(uint256 usd6Amount) {
        if (usd6Amount == 0) revert ZeroAmount();
        
        uint256 threshold = WITHDRAWAL_THRESHOLD_USD6;
        if (usd6Amount > threshold) {
            revert WithdrawalLimitExceeded(usd6Amount, threshold);
        }
        
        uint256 userBalance = s_balances[msg.sender][address(USDC)];
        if (usd6Amount > userBalance) {
            revert InsufficientBalance(usd6Amount, userBalance);
        }
        _;
    }
    
    /**
     * @notice Validates that an operation counter has not overflowed before allowing the operation.
     * @dev Checks the appropriate counter based on CounterType:
     *      - DEPOSIT: Checks s_depositCount
     *      - WITHDRAWAL: Checks s_withdrawCount  
     *      - SWAP: Checks s_swapCount
     *      
     *      Each counter must be strictly less than MAX_COUNTER_VALUE.
     *      This prevents theoretical uint256 overflow attacks and maintains counter integrity.
     * @param counterType The type of counter to validate (DEPOSIT, WITHDRAWAL, or SWAP).
     */
    modifier validateCounter(CounterType counterType) {
        if (counterType == CounterType.DEPOSIT) {
            if (s_depositCount >= MAX_COUNTER_VALUE) revert CounterOverflow();
        } else if (counterType == CounterType.WITHDRAWAL) {
            if (s_withdrawCount >= MAX_COUNTER_VALUE) revert CounterOverflow();
        } else if (counterType == CounterType.SWAP) {
            if (s_swapCount >= MAX_COUNTER_VALUE) revert CounterOverflow();
        }
        _;
    }

    /*///////////////////////////
            CONSTRUCTOR
    ///////////////////////////*/
    
    /**
     * @notice Initializes the KipuBankV3 contract with all required parameters.
     * @dev Sets up immutable values, validates parameters, and assigns initial roles.
     *      All parameters are validated before assignment to ensure contract correctness.
     *      
     *      Validation Rules:
     *      - All addresses must be non-zero
     *      - Bank capacity must be non-zero
     *      - Withdrawal threshold must be non-zero and <= bank capacity
     *      - Default slippage must be within MIN_SLIPPAGE_BPS and MAX_SLIPPAGE_BPS range
     *      
     *      Role Assignment:
     *      - admin receives: DEFAULT_ADMIN_ROLE, PAUSER_ROLE, TREASURER_ROLE
     *      - admin can later grant these roles to other addresses
     *      
     * @param admin The primary administrator address granted all initial roles.
     *              Should be a secure address (preferably multisig wallet) for mainnet deployments.
     * @param usdc The USDC contract address (6-decimal stablecoin used as internal reserve).
     *             Sepolia: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
     *             Mainnet: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
     * @param ethUsdFeed The Chainlink ETH/USD price feed contract address.
     *                   Sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306
     *                   Mainnet: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
     * @param uniswapRouter The Uniswap V2 Router02 contract address for executing swaps.
     *                      Sepolia: 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008
     *                      Mainnet: 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
     * @param bankCapUSD6 The initial maximum total capacity of the bank in USD-6.
     *                    Example: 1_000_000 * 1e6 = 1 million USD capacity
     * @param withdrawalThresholdUSD6 The maximum withdrawal limit per transaction in USD-6.
     *                                 Example: 10_000 * 1e6 = 10,000 USD per withdrawal
     *                                 Must be <= bankCapUSD6
     * @param defaultSlippageBps The default slippage tolerance in Basis Points (BPS).
     *                           Must be between 50 BPS (0.5%) and 500 BPS (5%).
     *                           Example: 100 BPS = 1% slippage tolerance
     */
    constructor(
        address admin,
        address usdc,
        address ethUsdFeed,
        address uniswapRouter,
        uint256 bankCapUSD6,
        uint256 withdrawalThresholdUSD6,
        uint256 defaultSlippageBps
    ) {
        // Validation for required non-zero addresses
        if (
            admin == address(0) ||
            usdc == address(0) ||
            ethUsdFeed == address(0) ||
            uniswapRouter == address(0)
        ) {
            revert InvalidParameters();
        }
        
        // Validation for capacity and withdrawal limits
        if (
            bankCapUSD6 == 0 ||
            withdrawalThresholdUSD6 == 0 ||
            withdrawalThresholdUSD6 > bankCapUSD6
        ) {
            revert InvalidParameters();
        }
        
        // Validation for default slippage range
        if (
            defaultSlippageBps < MIN_SLIPPAGE_BPS ||
            defaultSlippageBps > MAX_SLIPPAGE_BPS
        ) {
            revert InvalidSlippage();
        }
        
        // Role Assignment
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(TREASURER_ROLE, admin);
        
        // Immutable Assignment
        USDC = IERC20(usdc);
        ETH_USD_FEED = AggregatorV3Interface(ethUsdFeed);
        FEED_DECIMALS = ETH_USD_FEED.decimals();
        UNISWAP_ROUTER = IUniswapV2Router02(uniswapRouter);
        WITHDRAWAL_THRESHOLD_USD6 = withdrawalThresholdUSD6;
        
        // State Variable Assignment
        s_bankCapUSD6 = bankCapUSD6;
        s_defaultSlippageBps = defaultSlippageBps;
    }

    /*///////////////////////////
      EXTERNAL FUNCTIONS - DEPOSITS
    ///////////////////////////*/
    
    /**
     * @notice Deposits native ETH which is automatically swapped to USDC via Uniswap V2.
     * @dev Execution flow:
     *      1. Validates msg.value > 0
     *      2. Validates deposit and swap counters haven't overflowed
     *      3. Constructs swap path: [WETH, USDC]
     *      4. Calculates minimum output based on default slippage
     *      5. Executes swap via Uniswap Router (ETH sent as msg.value)
     *      6. Credits received USDC to user's balance
     *      7. Validates bank capacity not exceeded
     *      8. Increments counters and emits event
     *      
     *      Security features:
     *      - whenNotPaused: Respects emergency pause
     *      - nonReentrant: Prevents reentrancy attacks
     *      - validateCounter: Prevents counter overflow
     *      - try-catch on swap: Graceful error handling
     *      - 5-minute deadline: Prevents stale transactions
     *      
     *      Gas considerations:
     *      - More expensive than depositUSDC() due to swap
     *      - Typical cost: ~150k-200k gas depending on liquidity
     *      
     * @custom:example
     *      // Deposit 0.1 ETH (assuming 1 ETH = $2000)
     *      kipuBank.depositETH{value: 0.1 ether}();
     *      // Result: ~200 USDC credited to msg.sender
     */
    function depositETH()
        external
        payable
        whenNotPaused
        nonReentrant
        validateCounter(CounterType.DEPOSIT)
        validateCounter(CounterType.SWAP)
    {
        if (msg.value == 0) revert ZeroAmount();

        address[] memory path = new address[](2);
        path[0] = UNISWAP_ROUTER.WETH();
        path[1] = address(USDC);

        uint256 minAmountOut = _calculateMinAmountOut(msg.value, path);

        uint256[] memory amounts;
        try UNISWAP_ROUTER.swapExactETHForTokens{value: msg.value}(
            minAmountOut,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint256[] memory _amounts) {
            amounts = _amounts;
        } catch {
            revert SwapFailed();
        }

        uint256 usdcReceived = amounts[amounts.length - 1];
        _processDeposit(usdcReceived);
        
        unchecked { s_swapCount++; }

        emit Deposit(msg.sender, address(0), msg.value, usdcReceived);
    }
    
    /**
     * @notice Deposits USDC directly without any swap required.
     * @dev Execution flow:
     *      1. Validates amountUSDC > 0
     *      2. Validates deposit counter hasn't overflowed
     *      3. Transfers USDC from user to contract (requires prior approval)
     *      4. Credits USDC to user's balance
     *      5. Validates bank capacity not exceeded
     *      6. Increments counter and emits event
     *      
     *      Security features:
     *      - whenNotPaused: Respects emergency pause
     *      - nonReentrant: Prevents reentrancy attacks
     *      - validateCounter: Prevents counter overflow
     *      - SafeERC20: Protection against malicious token contracts
     *      
     *      Gas considerations:
     *      - Most gas-efficient deposit method
     *      - Typical cost: ~50k-80k gas
     *      - No Uniswap interaction required
     *      
     *      Prerequisites:
     *      - User must have approved the contract to spend their USDC
     *      - User must have sufficient USDC balance
     *      
     * @param amountUSDC The amount to deposit in USDC (6 decimals).
     *                   Example: 100 * 1e6 = 100 USDC
     *                   
     * @custom:example
     *      // First approve the contract
     *      USDC.approve(address(kipuBank), 100 * 1e6);
     *      // Then deposit
     *      kipuBank.depositUSDC(100 * 1e6);
     *      // Result: 100 USDC credited to msg.sender
     */
    function depositUSDC(uint256 amountUSDC)
        external
        whenNotPaused
        nonReentrant
        validateCounter(CounterType.DEPOSIT)
    {
        if (amountUSDC == 0) revert ZeroAmount();

        USDC.safeTransferFrom(msg.sender, address(this), amountUSDC);
        _processDeposit(amountUSDC);
        
        emit Deposit(msg.sender, address(USDC), amountUSDC, amountUSDC);
    }
    
    /**
     * @notice Deposits an ERC20 token and automatically swaps it to USDC via Uniswap V2.
     * @dev Execution flow:
     *      1. Validates amountToken > 0 and token is not USDC (use depositUSDC for USDC)
     *      2. Validates deposit and swap counters haven't overflowed
     *      3. Transfers token from user to contract (requires prior approval)
     *      4. Approves Uniswap Router to spend the tokens
     *      5. Constructs swap path: [token, USDC]
     *      6. Calculates minimum output using stricter of user's or protocol's slippage
     *      7. Executes swap via Uniswap Router
     *      8. Credits received USDC to user's balance
     *      9. Validates bank capacity not exceeded
     *      10. Increments counters and emits event
     *      
     *      Security features:
     *      - whenNotPaused: Respects emergency pause
     *      - nonReentrant: Prevents reentrancy attacks
     *      - validateCounter: Prevents counter overflow
     *      - Dual slippage protection: Uses stricter of user's or protocol's limit
     *      - try-catch on swap: Graceful error handling
     *      - forceApprove: Handles tokens with non-standard approve behavior
     *      
     *      Slippage logic:
     *      - Protocol calculates minOut using s_defaultSlippageBps
     *      - User provides their own minAmountOutUSDC
     *      - The stricter (higher) value is used as final protection
     *      
     *      Gas considerations:
     *      - Most expensive deposit method due to:
     *        - Token transfer from user
     *        - Approval transaction
     *        - Uniswap swap
     *      - Typical cost: ~180k-250k gas depending on token and liquidity
     *      
     *      Prerequisites:
     *      - Token must have a direct liquidity pair with USDC on Uniswap V2
     *      - User must have approved the contract to spend their tokens
     *      - User must have sufficient token balance
     *      
     * @param token The address of the ERC20 token to deposit.
     *              Must NOT be the USDC address (use depositUSDC instead).
     *              Must have a direct USDC pair on Uniswap V2.
     * @param amountToken The amount of tokens to deposit in the token's native decimals.
     *                    Example: For DAI (18 decimals): 100 * 1e18 = 100 DAI
     *                    Example: For USDT (6 decimals): 100 * 1e6 = 100 USDT
     * @param minAmountOutUSDC The minimum amount of USDC the user expects to receive (6 decimals).
     *                         This provides user-level slippage protection.
     *                         Set to 0 to rely solely on protocol's default slippage.
     *                         The contract will use the stricter of:
     *                         - This value
     *                         - Protocol's calculated minimum (based on s_defaultSlippageBps)
     *                         
     * @custom:example
     *      // Deposit 1000 DAI with 1% max slippage
     *      // Assuming DAI/USDC = 1:1, expecting ~990 USDC minimum
     *      DAI.approve(address(kipuBank), 1000 * 1e18);
     *      kipuBank.depositToken(
     *          address(DAI),
     *          1000 * 1e18,
     *          990 * 1e6  // User's min: 990 USDC (1% slippage)
     *      );
     *      // Result: ~1000 USDC credited (minus slippage/fees)
     */
    function depositToken(
        address token,
        uint256 amountToken,
        uint256 minAmountOutUSDC
    )
        external
        whenNotPaused
        nonReentrant
        validateCounter(CounterType.DEPOSIT)
        validateCounter(CounterType.SWAP)
    {
        if (amountToken == 0) revert ZeroAmount();
        if (token == address(USDC)) revert UnsupportedToken();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
        IERC20(token).forceApprove(address(UNISWAP_ROUTER), amountToken);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(USDC);
        
        uint256 contractMinExpectation = _calculateMinAmountOut(amountToken, path);
        uint256 finalMinOut = minAmountOutUSDC > contractMinExpectation ? minAmountOutUSDC : contractMinExpectation;

        uint256[] memory amounts;
        try UNISWAP_ROUTER.swapExactTokensForTokens(
            amountToken,
            finalMinOut,
            path,
            address(this),
            block.timestamp + 300
        ) returns (uint256[] memory _amounts) {
            amounts = _amounts;
        } catch {
            revert SwapFailed();
        }
        
        uint256 usdcReceived = amounts[amounts.length - 1];
        _processDeposit(usdcReceived);
        
        unchecked { s_swapCount++; }

        emit Deposit(msg.sender, token, amountToken, usdcReceived);
    }

    /*///////////////////////////
    EXTERNAL FUNCTIONS - WITHDRAWALS
    ///////////////////////////*/
    
    /**
     * @notice Withdraws ETH by swapping the user's USDC balance back to ETH via Uniswap V2.
     * @dev Execution flow:
     *      1. Validates withdrawal amount via validateWithdrawal modifier (non-zero, within limit, sufficient balance)
     *      2. Validates withdrawal counter hasn't overflowed
     *      3. Debits USD-6 from user's internal balance
     *      4. Approves Uniswap Router to spend contract's USDC
     *      5. Constructs swap path: [USDC, WETH]
     *      6. Executes swap via Uniswap Router (ETH sent directly to user)
     *      7. Increments counter and emits event
     *      
     *      Security features:
     *      - whenNotPaused: Respects emergency pause
     *      - nonReentrant: Prevents reentrancy attacks
     *      - validateWithdrawal: Comprehensive pre-checks
     *      - validateCounter: Prevents counter overflow
     *      - try-catch on swap: Graceful error handling
     *      - forceApprove: Handles USDC properly
     *      
     *      Important: Withdrawal happens BEFORE the swap
     *      - Balance is debited first (Checks-Effects-Interactions pattern)
     *      - If swap fails, transaction reverts and balance is restored
     *      - This prevents reentrancy and ensures atomic operation
     *      
     *      Gas considerations:
     *      - More expensive than withdrawUSDC() due to swap
     *      - Typical cost: ~150k-200k gas depending on liquidity
     *      
     *      Slippage handling:
     *      - minOut set to 0 for simplicity (swap must succeed)
     *      - User receives actual swap output (market rate)
     *      - Consider checking output amount off-chain before calling
     *      
     * @param usd6Amount The amount of USD-6 to withdraw from internal balance.
     *                   Example: 1000 * 1e6 = 1000 USD worth of ETH
     *                   This amount is debited from the user's USDC balance.
     *                   
     * @custom:example
     *      // Withdraw 500 USD worth of ETH (assuming ETH = $2000)
     *      kipuBank.withdrawETH(500 * 1e6);
     *      // Result: ~0.25 ETH sent to msg.sender
     *      //         500 USDC debited from balance
     */
    function withdrawETH(uint256 usd6Amount)
        external
        whenNotPaused
        nonReentrant
        validateWithdrawal(usd6Amount)
        validateCounter(CounterType.WITHDRAWAL)
    {
        _processWithdrawal(usd6Amount);

        USDC.forceApprove(address(UNISWAP_ROUTER), usd6Amount);
        
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = UNISWAP_ROUTER.WETH();
        
        uint256[] memory amounts;
        try UNISWAP_ROUTER.swapExactTokensForETH(
            usd6Amount,
            0,
            path,
            msg.sender,
            block.timestamp + 300
        ) returns (uint256[] memory _amounts) {
            amounts = _amounts;
        } catch {
            revert SwapFailed();
        }

        emit Withdrawal(msg.sender, address(0), usd6Amount, amounts[amounts.length - 1]);
    }
    
    /**
     * @notice Withdraws USDC directly from the user's internal balance.
     * @dev Execution flow:
     *      1. Validates withdrawal amount via validateWithdrawal modifier (non-zero, within limit, sufficient balance)
     *      2. Validates withdrawal counter hasn't overflowed
     *      3. Debits USD-6 from user's internal balance
     *      4. Transfers USDC from contract to user
     *      5. Increments counter and emits event
     *      
     *      Security features:
     *      - whenNotPaused: Respects emergency pause
     *      - nonReentrant: Prevents reentrancy attacks
     *      - validateWithdrawal: Comprehensive pre-checks
     *      - validateCounter: Prevents counter overflow
     *      - SafeERC20: Protection against malicious token behavior
     *      - Checks-Effects-Interactions: Balance updated before transfer
     *      
     *      Gas considerations:
     *      - Most gas-efficient withdrawal method
     *      - Typical cost: ~60k-90k gas
     *      - No Uniswap interaction required
     *      
     *      This is the recommended withdrawal method when:
     *      - User wants to keep funds in USDC
     *      - User wants to minimize gas costs
     *      - User wants to avoid swap slippage
     *      
     * @param usd6Amount The amount of USD-6 to withdraw.
     *                   Example: 250 * 1e6 = 250 USDC
     *                   
     * @custom:example
     *      // Withdraw 250 USDC
     *      kipuBank.withdrawUSDC(250 * 1e6);
     *      // Result: 250 USDC sent to msg.sender
     *      //         250 USDC debited from balance
     */
    function withdrawUSDC(uint256 usd6Amount)
        external
        whenNotPaused
        nonReentrant
        validateWithdrawal(usd6Amount)
        validateCounter(CounterType.WITHDRAWAL)
    {
        _processWithdrawal(usd6Amount);
        USDC.safeTransfer(msg.sender, usd6Amount);
        emit Withdrawal(msg.sender, address(USDC), usd6Amount, usd6Amount);
    }

    /*///////////////////////////
      INTERNAL FUNCTIONS
    ///////////////////////////*/

    /**
     * @notice Internal function to process a deposit by updating balances and validating capacity.
     * @dev Execution flow:
     *      1. Caches current total and max capacity (gas optimization)
     *      2. Checks if new deposit would exceed bank capacity
     *      3. Updates user's USDC balance (under address(USDC) key)
     *      4. Updates total bank balance
     *      5. Increments deposit counter
     *      
     *      All arithmetic is unchecked because:
     *      - Capacity check prevents overflow of s_totalUSD6
     *      - Counter validation (in modifier) prevents s_depositCount overflow
     *      - User balance addition cannot overflow due to capacity limit
     *      
     *      Note: This function does NOT emit events. Events are emitted by the
     *      calling public functions (depositETH, depositUSDC, depositToken) which
     *      have context about the input token type and amount.
     *      
     * @param amountUSD6 The amount in USD-6 to credit to the user's balance.
     *                   This is the final amount after any swaps have occurred.
     */
    function _processDeposit(uint256 amountUSD6) internal {
        uint256 currentTotal = s_totalUSD6;
        uint256 maxCap = s_bankCapUSD6;
        
        if (currentTotal + amountUSD6 > maxCap) {
            revert CapExceeded(currentTotal + amountUSD6, maxCap);
        }

        unchecked {
            s_balances[msg.sender][address(USDC)] += amountUSD6;
            s_totalUSD6 += amountUSD6;
            s_depositCount++;
        }
    }

    /**
     * @notice Internal function to process a withdrawal by updating balances.
     * @dev Execution flow:
     *      1. Debits amount from user's USDC balance (under address(USDC) key)
     *      2. Decreases total bank balance
     *      3. Increments withdrawal counter
     *      
     *      All arithmetic is unchecked because:
     *      - validateWithdrawal modifier ensures sufficient balance (no underflow)
     *      - s_totalUSD6 subtraction cannot underflow (sum of all balances)
     *      - Counter validation (in modifier) prevents s_withdrawCount overflow
     *      
     *      Note: This function does NOT:
     *      - Transfer tokens (done by calling function)
     *      - Emit events (done by calling function)
     *      - Validate parameters (done by validateWithdrawal modifier)
     *      
     *      The separation allows different withdrawal methods (ETH vs USDC) to
     *      share common balance update logic while handling token transfers differently.
     *      
     * @param amountUSD6 The amount in USD-6 to debit from the user's balance.
     */
    function _processWithdrawal(uint256 amountUSD6) internal {
        unchecked {
            s_balances[msg.sender][address(USDC)] -= amountUSD6;
            s_totalUSD6 -= amountUSD6;
            s_withdrawCount++;
        }
    }
    
    /**
     * @notice Calculates the minimum expected output amount for a swap based on default slippage.
     * @dev Calculation process:
     *      1. Query Uniswap Router for expected output (no slippage)
     *      2. Apply protocol's default slippage tolerance
     *      3. Return the minimum acceptable output
     *      
     *      Formula:
     *      minAmountOut = expectedOut * (10000 - s_defaultSlippageBps) / 10000
     *      
     *      Example with 100 BPS (1%) slippage:
     *      - Expected output: 1000 USDC
     *      - Slippage: 100 BPS
     *      - minAmountOut = 1000 * (10000 - 100) / 10000 = 1000 * 9900 / 10000 = 990 USDC
     *      
     *      This minimum is used as protection against:
     *      - Normal market volatility
     *      - Minor price fluctuations between tx submission and execution
     *      - Small amounts of slippage/fees
     *      
     *      For depositToken(), the stricter of this value and the user's provided
     *      minAmountOutUSDC is used for additional protection.
     *      
     * @param amountIn The input amount for the swap in the input token's decimals.
     * @param path The Uniswap swap path array.
     *             Must be 2 elements: [inputToken, outputToken]
     *             Examples:
     *             - [WETH, USDC] for ETH → USDC
     *             - [DAI, USDC] for DAI → USDC
     * @return minAmountOut The calculated minimum acceptable output amount after applying slippage.
     */
    function _calculateMinAmountOut(uint256 amountIn, address[] memory path) internal view returns (uint256 minAmountOut) {
        uint256[] memory amountsOut = UNISWAP_ROUTER.getAmountsOut(amountIn, path);
        uint256 expected = amountsOut[amountsOut.length - 1];
        minAmountOut = (expected * (BPS_DENOMINATOR - s_defaultSlippageBps)) / BPS_DENOMINATOR;
    }

    /*///////////////////////////
    EXTERNAL FUNCTIONS - ADMIN
    ///////////////////////////*/
    
    /**
     * @notice Updates the maximum capacity of the bank (admin only).
     * @dev Allows the admin to adjust the total deposit limit dynamically.
     *      
     *      Use cases:
     *      - Gradual rollout: Start with low cap, increase as confidence grows
     *      - Risk management: Reduce cap if security concerns arise
     *      - Scaling: Increase cap as protocol matures and liquidity improves
     *      
     *      Security considerations:
     *      - Only DEFAULT_ADMIN_ROLE can call this
     *      - Cannot be set to zero (would lock all deposits)
     *      - Can be set below current s_totalUSD6 (stops new deposits but allows withdrawals)
     *      - Change takes effect immediately
     *      
     *      Note: Reducing the cap below current total does NOT force withdrawals.
     *      It simply prevents new deposits until total drops below the new cap.
     *      
     * @param newCap The new maximum capacity limit in USD-6.
     *               Must be greater than zero.
     *               Example: 5_000_000 * 1e6 = 5 million USD capacity
     */
    function setBankCapUSD6(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCap == 0) revert InvalidParameters();
        s_bankCapUSD6 = newCap;
        emit BankCapUpdated(newCap);
    }
    
    /**
     * @notice Updates the default slippage tolerance for swaps (admin only).
     * @dev Allows the admin to adjust slippage protection based on market conditions.
     *      
     *      Use cases:
     *      - High volatility: Increase slippage to prevent failed swaps
     *      - Low volatility: Decrease slippage for better user protection
     *      - Different networks: Adjust for varying liquidity depths
     *      
     *      Constraints:
     *      - Must be between MIN_SLIPPAGE_BPS (50 = 0.5%) and MAX_SLIPPAGE_BPS (500 = 5%)
     *      - Values outside this range are considered unsafe
     *      
     *      Security considerations:
     *      - Only DEFAULT_ADMIN_ROLE can call this
     *      - Change affects all future swaps immediately
     *      - Does not affect user-provided minAmountOut in depositToken()
     *      - The stricter protection always applies
     *      
     *      Recommended values:
     *      - Testnet: 100-200 BPS (1-2%) for testing flexibility
     *      - Mainnet stable markets: 50-100 BPS (0.5-1%)
     *      - Mainnet volatile markets: 100-300 BPS (1-3%)
     *      - Never exceed 500 BPS (5%) due to MEV risk
     *      
     * @param newSlippageBps The new slippage tolerance value in Basis Points (BPS).
     *                       Must be between 50 (0.5%) and 500 (5%).
     *                       Example: 150 = 1.5% slippage tolerance
     */
    function setDefaultSlippage(uint256 newSlippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSlippageBps < MIN_SLIPPAGE_BPS || newSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippage();
        }
        s_defaultSlippageBps = newSlippageBps;
        emit SlippageUpdated(newSlippageBps);
    }
    
    /**
     * @notice Pauses all deposit and withdrawal functions (PAUSER_ROLE only).
     * @dev Emergency stop mechanism to halt all user-facing operations.
     *      
     *      What gets paused:
     *      - depositETH()
     *      - depositUSDC()
     *      - depositToken()
     *      - withdrawETH()
     *      - withdrawUSDC()
     *      
     *      What remains active:
     *      - Admin functions (setBankCapUSD6, setDefaultSlippage, rescue)
     *      - View functions (getBalanceUSD6, getETHPrice)
     *      - Role management (grantRole, revokeRole)
     *      - unpause() (to resume operations)
     *      
     *      Use cases:
     *      - Security incident detected
     *      - Oracle malfunction
     *      - Uniswap liquidity crisis
     *      - Critical bug discovered
     *      - Regulatory requirement
     *      
     *      Best practices:
     *      - Assign PAUSER_ROLE to monitoring systems for automatic response
     *      - Assign to multiple trusted operators for redundancy
     *      - Always communicate with users when pausing
     *      - Have a clear unpause procedure and criteria
     *      
     *      Important: Pausing does NOT:
     *      - Freeze user balances
     *      - Transfer any funds
     *      - Change any state except the paused flag
     *      - Prevent admin rescue operations
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpauses the contract and resumes normal operations (PAUSER_ROLE only).
     * @dev Reverses the pause() function, allowing deposits and withdrawals again.
     *      
     *      Prerequisites before unpausing:
     *      - Root cause of pause has been identified and resolved
     *      - All systems (oracles, Uniswap, etc.) are confirmed operational
     *      - Security review completed if pause was security-related
     *      - Users have been notified that operations will resume
     *      
     *      Best practices:
     *      - Test deposits/withdrawals on testnet first if possible
     *      - Monitor for abnormal activity immediately after unpausing
     *      - Have pause mechanism ready to re-engage if issues recur
     *      - Document the incident and resolution for future reference
     *      
     *      Note: State remains unchanged during pause period:
     *      - All balances preserved
     *      - Counters not affected
     *      - Configuration settings intact
     *      - Only the paused flag changes
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Emergency function to recover stuck tokens or native ETH (TREASURER_ROLE only).
     * @dev Allows recovery of assets that were sent to the contract by mistake or are otherwise stuck.
     *      
     *      Common rescue scenarios:
     *      - User accidentally sent tokens directly instead of using deposit functions
     *      - Airdropped tokens sent to the contract address
     *      - Native ETH stuck from failed operations
     *      - Dust amounts from rounding errors
     *      - Tokens sent as spam/scam attempts
     *      
     *      Security features:
     *      - Only TREASURER_ROLE can execute
     *      - Separate role from admin for better security separation
     *      - Zero amount validation (gas savings)
     *      - SafeERC20 for token transfers
     *      - Custom error for failed ETH transfers
     *      
     *      Important considerations:
     *      - This does NOT affect user balances (those are accounting entries)
     *      - This recovers actual token balances held by the contract
     *      - Normal operations don't create "stuck" funds
     *      - Should only be used for genuinely stuck or mistaken transfers
     *      
     *      Best practices:
     *      - Assign TREASURER_ROLE to a multisig wallet
     *      - Document every rescue operation
     *      - Verify token balances before and after
     *      - Return accidentally sent user funds when possible
     *      - Keep a public log of rescue operations for transparency
     *      
     * @param token The address of the token to rescue.
     *              Use address(0) for native ETH.
     *              Use any ERC20 address for token rescue.
     * @param amount The amount to rescue and send to the TREASURER.
     *               For ETH: amount in wei (18 decimals)
     *               For tokens: amount in token's native decimals
     *               Example: 1000 * 1e6 = 1000 USDC
     *               
     * @custom:example-eth
     *      // Rescue 0.5 ETH stuck in contract
     *      kipuBank.rescue(address(0), 0.5 ether);
     *      
     * @custom:example-token
     *      // Rescue 100 accidentally sent DAI
     *      kipuBank.rescue(address(DAI), 100 * 1e18);
     */
    function rescue(address token, uint256 amount) external onlyRole(TREASURER_ROLE) {
        if (amount == 0) revert ZeroAmount();

        if (token == address(0)) {
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /*///////////////////////////
        VIEW FUNCTIONS
    ///////////////////////////*/
    
    /**
     * @notice Returns the user's current balance in USD-6 format.
     * @dev Reads from the internal accounting mapping s_balances.
     *      All balances are stored under the USDC address key since V3 uses
     *      USDC as the internal reserve currency.
     *      
     *      Return value represents:
     *      - The amount of USDC-equivalent the user can withdraw
     *      - Precision: 6 decimal places (USD-6 format)
     *      - 1,000,000 = 1 USD
     *      - 1,000,000,000 = 1,000 USD
     *      
     *      This balance is:
     *      - Increased by deposits (after swaps if applicable)
     *      - Decreased by withdrawals (before swaps if applicable)
     *      - Not affected by market price changes (stored as USDC, not original tokens)
     *      - Isolated per user (no commingling)
     *      
     *      Gas cost: Very low (~2-3k gas) - single storage read
     *      
     * @param user The address of the user whose balance to query.
     * @return balance The user's balance in USD-6 format (6 decimals).
     *         
     * @custom:example
     *      // Check Alice's balance
     *      uint256 balance = kipuBank.getBalanceUSD6(alice);
     *      // If returns 1500000000, Alice has 1,500 USD worth of balance
     *      // She can withdraw up to 1,500 USDC or equivalent ETH
     */
    function getBalanceUSD6(address user) external view returns (uint256 balance) {
        return s_balances[user][address(USDC)];
    }

    /**
     * @notice Returns the current ETH/USD price from the Chainlink oracle with security validations.
     * @dev Queries the Chainlink ETH/USD price feed and performs critical security checks:
     *      
     *      Security validations:
     *      1. Price must be positive (p > 0)
     *      2. Round must be complete (answeredInRound >= roundId)
     *      3. Data must be fresh (updatedAt within ORACLE_HEARTBEAT)
     *      
     *      If any validation fails, the appropriate error is thrown:
     *      - OracleCompromised: For negative prices or incomplete rounds
     *      - StalePrice: For outdated data beyond ORACLE_HEARTBEAT (1 hour)
     *      
     *      Return values:
     *      - price: The current ETH price in USD with FEED_DECIMALS precision
     *      - decimals: The number of decimals used (typically 8)
     *      
     *      Example return values:
     *      - price: 200000000000 (8 decimals)
     *      - decimals: 8
     *      - Interpretation: 2000.00000000 USD per ETH
     *      
     *      This function is view-only and can be called:
     *      - Externally by users to check current price
     *      - Off-chain for calculations before transactions
     *      - By front-ends to display exchange rates
     *      
     *      Note: This does NOT execute any state changes.
     *      Internal functions like _ethWeiToUSD6 use ETH_USD_FEED directly
     *      for gas optimization, but perform the same validations.
     *      
     *      Gas cost: Low (~10-15k gas) - external call to Chainlink oracle
     *      
     * @return price The current ETH/USD price scaled by 10^FEED_DECIMALS.
     *               Example: 200000000000 represents $2000.00000000
     * @return decimals The number of decimals in the returned price (typically 8).
     *                  
     * @custom:example
     *      // Get current ETH price
     *      (uint256 price, uint8 decimals) = kipuBank.getETHPrice();
     *      // If price = 250000000000 and decimals = 8
     *      // Then ETH = $2,500.00000000 USD
     *      
     *      // Calculate 1 ETH in USDC (6 decimals)
     *      uint256 usdcValue = (1 ether * price) / (10 ** (decimals + 12));
     *      // Results in: 2500000000 (2500 USDC in 6 decimals)
     */
    function getETHPrice() external view returns (uint256 price, uint8 decimals) {
        (
            uint80 roundId,
            int256 p,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ETH_USD_FEED.latestRoundData();

        if (p <= 0 || answeredInRound < roundId) revert OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert StalePrice();

        return (uint256(p), FEED_DECIMALS);
    }

    /**
     * @notice Fallback function to receive native ETH.
     * @dev Restricted to only accept ETH from the Uniswap Router contract.
     *      
     *      Purpose:
     *      - Allows contract to receive ETH when Uniswap Router executes swapExactTokensForETH
     *      - The Router sends ETH directly to the recipient (in this case, the user)
     *      - This receive function should rarely be triggered in normal operations
     *      
     *      Security:
     *      - Blocks direct ETH sends from users (prevents accounting errors)
     *      - Only UNISWAP_ROUTER address is whitelisted
     *      - All other senders trigger UseDepositETH error
     *      
     *      Why this restriction?
     *      - Direct ETH sends don't update accounting (no deposit recorded)
     *      - Would create "stuck" ETH without corresponding user balance
     *      - Users must use depositETH() for proper tracking
     *      
     *      Normal flow for users:
     *      - To deposit ETH: call depositETH() (not send ETH directly)
     *      - To withdraw ETH: call withdrawETH() (Router sends ETH directly to user, not via this)
     *      
     *      This function should only execute:
     *      - During testing with mock routers
     *      - In abnormal edge cases
     *      - During rescue operations involving ETH
     *      
     * @custom:security
     *      If you see ETH in the contract balance that wasn't from the Router,
     *      it may need to be rescued via the rescue() function by the TREASURER.
     */
    receive() external payable {
        if (msg.sender != address(UNISWAP_ROUTER)) {
            revert UseDepositETH();
        }
    }
}
