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
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol"; // Correct interface import

/**
 * @title KipuBankV3
 * @author Elian Guevara
 * @notice DeFi Banking Protocol. Allows deposits in ETH, USDC, or other ERC20 tokens.
 * @dev All assets are converted to and stored internally as USDC (USD-6). 
 * Implements OpenZeppelin AccessControl, Pausable, and ReentrancyGuard for security.
 */
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*///////////////////////////
            ERRORS
    ///////////////////////////*/
    
    /// @notice Thrown when an input amount is zero.
    error ZeroAmount();
    
    /// @notice Thrown when the deposit exceeds the bank's maximum capacity.
    /// @param requested The total balance that was attempted (s_totalUSD6 + amountUSD6).
    /// @param available The maximum capacity currently allowed (s_bankCapUSD6).
    error CapExceeded(uint256 requested, uint256 available);
    
    /// @notice Thrown when the user tries to withdraw more than their available balance.
    /// @param requested The requested withdrawal amount in USD-6.
    /// @param balance The user's available balance in USD-6.
    error InsufficientBalance(uint256 requested, uint256 balance);
    
    /// @notice Thrown when oracle data is invalid (e.g., price <= 0 or round inconsistency).
    error OracleCompromised();
    
    /// @notice Thrown when the oracle price data is outdated (older than ORACLE_HEARTBEAT).
    error StalePrice();
    
    /// @notice Thrown when a withdrawal exceeds the configured per-transaction limit.
    /// @param requested The requested amount in USD-6.
    /// @param limit The configured maximum withdrawal limit per transaction in USD-6.
    error WithdrawalLimitExceeded(uint256 requested, uint256 limit);
    
    /// @notice Thrown when a native ETH transfer fails (e.g., during rescue operation).
    error ETHTransferFailed();
    
    /// @notice Thrown when constructor parameters are invalid (e.g., zero addresses or invalid caps).
    error InvalidParameters();
    
    /// @notice Thrown when a direct ETH transfer is attempted via the receive function (must use depositETH).
    error UseDepositETH();
    
    /// @notice Thrown when a swap operation fails on the Uniswap router.
    error SwapFailed();
    
    /// @notice Thrown when slippage parameters are outside the MIN/MAX bounds.
    error InvalidSlippage();
    
    /// @notice Thrown when an unsupported token is used (e.g., depositing USDC via depositToken).
    error UnsupportedToken();
    
    /// @notice Thrown when an internal operation counter reaches its maximum value.
    error CounterOverflow();

    /*///////////////////////////
        TYPE DECLARATIONS
    ///////////////////////////*/
    
    /**
     * @notice Enum to classify the type of operation for counter tracking.
     */
    enum CounterType {
        DEPOSIT,
        WITHDRAWAL,
        SWAP
    }

    /*///////////////////////////
          STATE VARIABLES
    ///////////////////////////*/
    
    // ======== ROLES ========
    
    /// @notice Role identifier for pausing and unpausing the contract functions.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    /// @notice Role identifier for the treasurer, allowing recovery of stuck funds.
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    
    // ======== CONSTANTS ========
    
    /// @notice Maximum allowed value for operation counters (uint256.max - 1). Made public for testing access.
    uint256 public constant MAX_COUNTER_VALUE = type(uint256).max - 1;
    
    /// @notice Maximum acceptable age for oracle data in seconds (3600 seconds = 1 hour).
    uint32 public constant ORACLE_HEARTBEAT = 3600;
    
    /// @notice The decimal places used by USDC and for internal accounting (6).
    uint8 public constant USD_DECIMALS = 6;
    
    /// @notice Minimum acceptable slippage tolerance in Basis Points (BPS). 50 BPS = 0.5%.
    uint256 public constant MIN_SLIPPAGE_BPS = 50;
    
    /// @notice Maximum acceptable slippage tolerance in Basis Points (BPS). 500 BPS = 5%.
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    
    /// @notice Denominator used for Basis Point calculations (10000).
    uint256 private constant BPS_DENOMINATOR = 10000;
    
    /// @notice Current version string of the contract.
    string public constant VERSION = "3.0.1";
    
    // ======== IMMUTABLES ========
    
    /// @notice The USDC token contract address (internal reserve currency).
    IERC20 public immutable USDC;
    
    /// @notice The Chainlink Aggregator interface for the ETH/USD price feed.
    AggregatorV3Interface public immutable ETH_USD_FEED;
    
    /// @notice The decimal places reported by the Chainlink price feed.
    uint8 public immutable FEED_DECIMALS;
    
    /// @notice The immutable Uniswap V2 Router contract interface.
    IUniswapV2Router02 public immutable UNISWAP_ROUTER;
    
    /// @notice The maximum withdrawal amount allowed per transaction, denominated in USD-6.
    uint256 public immutable WITHDRAWAL_THRESHOLD_USD6;

    // ======== STORAGE ========
    
    /**
     * @notice User balances in USD-6. 
     * @dev Only the key for `address(USDC)` is used for internal storage.
     * Mapped structure: user => token (always address(USDC)) => amount in USD-6.
     */
    mapping(address user => mapping(address token => uint256 usd6)) private s_balances;
    
    /// @notice The total outstanding balance across all users, denominated in USD-6.
    uint256 public s_totalUSD6;
    
    /// @notice The maximum total capacity (cap) of the bank in USD-6.
    uint256 public s_bankCapUSD6;
    
    /// @notice The default slippage tolerance applied to swaps, measured in Basis Points (BPS).
    uint256 public s_defaultSlippageBps;
    
    /// @notice Counter for successful deposit operations.
    uint256 public s_depositCount;
    
    /// @notice Counter for successful withdrawal operations.
    uint256 public s_withdrawCount;
    
    /// @notice Counter for swap operations initiated by the contract.
    uint256 public s_swapCount;

    /*///////////////////////////
            EVENTS
    ///////////////////////////*/
    
    /**
     * @notice Emitted when a deposit is successfully registered.
     * @param user The address of the user who made the deposit.
     * @param tokenIn The address of the token deposited (address(0) for native ETH).
     * @param amountIn The native amount of the token deposited.
     * @param creditedUSD6 The amount of USDC-6 credited to the user's balance.
     */
    event Deposit(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 creditedUSD6
    );

    /**
     * @notice Emitted when a withdrawal is successfully processed.
     * @param user The address of the user who made the withdrawal.
     * @param tokenOut The address of the token withdrawn (address(0) for native ETH).
     * @param debitedUSD6 The amount of USD-6 debited from the user's balance.
     * @param amountTokenOut The native amount of the token sent to the user.
     */
    event Withdrawal(
        address indexed user,
        address indexed tokenOut,
        uint256 debitedUSD6,
        uint256 amountTokenOut
    );

    /// @notice Emitted when the bank's maximum capacity is updated.
    /// @param newCapUSD6 The new maximum capacity in USD-6.
    event BankCapUpdated(uint256 newCapUSD6);
    
    /// @notice Emitted when the default slippage tolerance is updated.
    /// @param newSlippageBps The new slippage value in Basis Points (BPS).
    event SlippageUpdated(uint256 newSlippageBps);
    
    /*///////////////////////////
            MODIFIERS
    ///////////////////////////*/
    
    /**
     * @notice Validates withdrawal parameters: non-zero amount, within transaction limit, 
     * and sufficient user balance.
     * @param usd6Amount The amount in USD-6 to withdraw.
     */
    modifier validateWithdrawal(uint256 usd6Amount) {
        if (usd6Amount == 0) revert ZeroAmount();
        
        uint256 threshold = WITHDRAWAL_THRESHOLD_USD6;
        if (usd6Amount > threshold) {
            revert WithdrawalLimitExceeded(usd6Amount, threshold);
        }
        
        // In V3, balance is stored only under the USDC key.
        uint256 userBalance = s_balances[msg.sender][address(USDC)];
        if (usd6Amount > userBalance) {
            revert InsufficientBalance(usd6Amount, userBalance);
        }
        _;
    }
    
    /**
     * @notice Validates that an operation counter has not overflowed.
     * @param counterType The type of counter to validate.
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
     * @notice Initializes the contract, assigning roles and setting immutable state.
     * @param admin The primary administrator address, granted all initial roles.
     * @param usdc The USDC contract address (the internal reserve currency).
     * @param ethUsdFeed The Chainlink price feed address for ETH/USD.
     * @param uniswapRouter The Uniswap V2 router address.
     * @param bankCapUSD6 The initial maximum capacity of the bank in USD-6.
     * @param withdrawalThresholdUSD6 The maximum withdrawal limit per transaction in USD-6.
     * @param defaultSlippageBps The default slippage tolerance in Basis Points (BPS).
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
     * @notice Deposits native ETH, which is automatically swapped to USDC via Uniswap.
     * @dev The ETH value is sent to the Uniswap router for the swap.
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

        // Calculate minimum USDC output based on default slippage
        uint256 minAmountOut = _calculateMinAmountOut(msg.value, path);

        uint256[] memory amounts;
        try UNISWAP_ROUTER.swapExactETHForTokens{value: msg.value}(
            minAmountOut,
            path,
            address(this),
            block.timestamp + 300 // 5-minute deadline
        ) returns (uint256[] memory _amounts) {
            amounts = _amounts;
        } catch {
            revert SwapFailed();
        }

        // USDC is received by the contract and credited
        uint256 usdcReceived = amounts[amounts.length - 1];
        _processDeposit(usdcReceived);
        
        unchecked { s_swapCount++; }

        // address(0) indicates the input was native ETH
        emit Deposit(msg.sender, address(0), msg.value, usdcReceived);
    }
    
    /**
     * @notice Deposits USDC directly, without any swap required.
     * @param amountUSDC The amount to deposit in USDC (USD-6).
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
     * @notice Deposits an ERC20 token and swaps it to USDC.
     * @param token The address of the ERC20 token to deposit.
     * @param amountToken The native amount of the token to deposit.
     * @param minAmountOutUSDC The minimum amount of USDC-6 the user expects, 
     * used to enforce slippage tolerance (the stricter value is used).
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
        // USDC should be deposited using depositUSDC
        if (token == address(USDC)) revert UnsupportedToken();

        // Transfer tokens from user to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
        // Approve the router to spend the tokens
        IERC20(token).forceApprove(address(UNISWAP_ROUTER), amountToken);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(USDC);
        
        // Calculate the minimum output required by the protocol (using default slippage)
        uint256 contractMinExpectation = _calculateMinAmountOut(amountToken, path);
        
        // Use the stricter slippage constraint: user-provided or protocol default.
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
     * @notice Withdraws native ETH. Swaps the internal USDC balance back to ETH.
     * @param usd6Amount The amount of USD-6 to withdraw (debited from the USDC balance).
     */
    function withdrawETH(uint256 usd6Amount)
        external
        whenNotPaused
        nonReentrant
        validateWithdrawal(usd6Amount) // Uses the simplified modifier
        validateCounter(CounterType.WITHDRAWAL)
    {
        _processWithdrawal(usd6Amount);

        // Approve the router to spend the contract's USDC
        USDC.forceApprove(address(UNISWAP_ROUTER), usd6Amount);
        
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = UNISWAP_ROUTER.WETH();
        
        uint256[] memory amounts;
        try UNISWAP_ROUTER.swapExactTokensForETH(
            usd6Amount,
            0, // Min out 0 to simplify: the swap just needs to succeed
            path,
            msg.sender,
            block.timestamp + 300
        ) returns (uint256[] memory _amounts) {
            amounts = _amounts;
        } catch {
            revert SwapFailed();
        }

        // ETH is sent directly to msg.sender by the router
        emit Withdrawal(msg.sender, address(0), usd6Amount, amounts[amounts.length - 1]);
    }
    
    /**
     * @notice Withdraws USDC directly.
     * @param usd6Amount The amount of USD-6 to withdraw.
     */
    function withdrawUSDC(uint256 usd6Amount)
        external
        whenNotPaused
        nonReentrant
        validateWithdrawal(usd6Amount) // Uses the simplified modifier
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
     * @notice Updates the user's balance and total bank balance, checking against the capacity.
     * @param amountUSD6 The amount in USD-6 to add to the balance.
     */
    function _processDeposit(uint256 amountUSD6) internal {
        // Caching state variables
        uint256 currentTotal = s_totalUSD6;
        uint256 maxCap = s_bankCapUSD6;
        
        // Check if the deposit exceeds the bank's capacity
        if (currentTotal + amountUSD6 > maxCap) {
            revert CapExceeded(currentTotal + amountUSD6, maxCap);
        }

        unchecked {
            // Credit the balance under the USDC key (internal reserve currency)
            s_balances[msg.sender][address(USDC)] += amountUSD6;
            s_totalUSD6 += amountUSD6;
            s_depositCount++;
        }
    }

    /**
     * @notice Updates the user's balance and total bank balance for a withdrawal.
     * @param amountUSD6 The amount in USD-6 to subtract from the balance.
     */
    function _processWithdrawal(uint256 amountUSD6) internal {
        unchecked {
            // Debit the balance from the USDC key
            s_balances[msg.sender][address(USDC)] -= amountUSD6;
            s_totalUSD6 -= amountUSD6;
            s_withdrawCount++;
        }
    }
    
    /**
     * @notice Calculates the minimum expected output amount based on the default slippage.
     * @param amountIn Input amount.
     * @param path Swap path.
     * @return minAmountOut The calculated minimum output token amount.
     */
    function _calculateMinAmountOut(uint256 amountIn, address[] memory path) internal view returns (uint256 minAmountOut) {
        // Get the expected amount (without slippage) from the router
        uint256[] memory amountsOut = UNISWAP_ROUTER.getAmountsOut(amountIn, path);
        uint256 expected = amountsOut[amountsOut.length - 1];
        // Apply the default slippage tolerance
        minAmountOut = (expected * (BPS_DENOMINATOR - s_defaultSlippageBps)) / BPS_DENOMINATOR;
    }

    /*///////////////////////////
    EXTERNAL FUNCTIONS - ADMIN
    ///////////////////////////*/
    
    /**
     * @notice Sets a new maximum capacity for the bank (Admin only).
     * @param newCap The new capacity limit in USD-6.
     */
    function setBankCapUSD6(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCap == 0) revert InvalidParameters();
        s_bankCapUSD6 = newCap;
        emit BankCapUpdated(newCap);
    }
    
    /**
     * @notice Sets a new default slippage tolerance (Admin only).
     * @param newSlippageBps The new slippage value in Basis Points (BPS).
     */
    function setDefaultSlippage(uint256 newSlippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSlippageBps < MIN_SLIPPAGE_BPS || newSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippage();
        }
        s_defaultSlippageBps = newSlippageBps;
        emit SlippageUpdated(newSlippageBps);
    }
    
    /**
     * @notice Pauses the deposit and withdrawal functionalities of the contract (PAUSER_ROLE only).
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpauses the contract functionalities (PAUSER_ROLE only).
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Allows the treasurer to recover stuck ERC20 tokens or native ETH from the contract (TREASURER_ROLE only).
     * @param token The address of the token to rescue (address(0) for native ETH).
     * @param amount The amount of token/ETH to send.
     */
    function rescue(address token, uint256 amount) external onlyRole(TREASURER_ROLE) {
        if (amount == 0) revert ZeroAmount();

        if (token == address(0)) {
            // Rescue native ETH
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert ETHTransferFailed();
        } else {
            // Rescue ERC20 token
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /*///////////////////////////
        VIEW FUNCTIONS
    ///////////////////////////*/
    
    /**
     * @notice Gets the user's balance in USDC-6 (internal reserve currency).
     * @param user The user's address.
     * @return Balance The user's balance in USD-6.
     */
    function getBalanceUSD6(address user) external view returns (uint256 Balance) {
        return s_balances[user][address(USDC)];
    }

    /**
     * @notice Gets the current ETH/USD price from Chainlink.
     * @dev Includes security checks for compromised or stale data.
     * @return price The current price (scaled by 10^FEED_DECIMALS).
     * @return decimals The decimals of the returned price.
     */
    function getETHPrice() external view returns (uint256 price, uint8 decimals) {
        (
            uint80 roundId,
            int256 p,
            , // startedAt (omitted)
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ETH_USD_FEED.latestRoundData();

        // Security Validations
        if (p <= 0 || answeredInRound < roundId) revert OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert StalePrice();

        return (uint256(p), FEED_DECIMALS);
    }

    /**
     * @notice Fallback function to receive ETH, only permitted from the Uniswap Router.
     */
    receive() external payable {
        if (msg.sender != address(UNISWAP_ROUTER)) {
            revert UseDepositETH();
        }
    }
}