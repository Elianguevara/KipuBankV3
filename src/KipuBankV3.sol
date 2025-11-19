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
// CORRECTED CHAINLINK IMPORT PATH (This must match your library version)
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";// Minimal Uniswap Router Interface

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForETH(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
        
    function WETH() external view returns (address);
}

/**
 * @title KipuBankV3
 * @author Elian Guevara
 * @notice DeFi Banking Protocol. Allows deposits in ETH, USDC, or ERC20 tokens.
 * @dev All assets are converted to and stored as USDC. Implements AccessControl and Pausable.
 * Follows strict Solidity style guide and security patterns.
 */
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*///////////////////////////
           ERRORS
    ///////////////////////////*/
    
    /// @notice Thrown when an amount is zero
    error ZeroAmount();
    
    /// @notice Thrown when the bank capacity would be exceeded
    /// @param requested The amount attempted to deposit
    /// @param available The maximum capacity currently allowed
    error CapExceeded(uint256 requested, uint256 available);
    
    /// @notice Thrown when user has insufficient balance for withdrawal
    /// @param requested The amount requested
    /// @param balance The user's available balance
    error InsufficientBalance(uint256 requested, uint256 balance);
    
    /// @notice Thrown when the oracle data is invalid
    error OracleCompromised();
    
    /// @notice Thrown when the oracle price is stale (outdated)
    error StalePrice();
    
    /// @notice Thrown when a withdrawal exceeds the per-transaction limit
    /// @param requested The requested amount
    /// @param limit The configured limit
    error WithdrawalLimitExceeded(uint256 requested, uint256 limit);
    
    /// @notice Thrown when an ETH transfer fails
    error ETHTransferFailed();
    
    /// @notice Thrown when constructor parameters are invalid
    error InvalidParameters();
    
    /// @notice Thrown when direct ETH transfer is attempted (must use depositETH)
    error UseDepositETH();
    
    /// @notice Thrown when a swap operation fails
    error SwapFailed();
    
    /// @notice Thrown when slippage parameters are invalid
    error InvalidSlippage();
    
    /// @notice Thrown when an unsupported token is used
    error UnsupportedToken();
    
    /// @notice Thrown when the operation counter overflows
    error CounterOverflow();

    /*///////////////////////////
       TYPE DECLARATIONS
    ///////////////////////////*/
    
    /**
     * @notice Enum to track operation types for counters
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
    
    /// @notice Role identifier for pausing the contract
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    /// @notice Role identifier for the treasurer (rescue funds)
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    
    // ======== CONSTANTS ========
    
    /// @notice Max value for counters to prevent overflow
    uint256 private constant MAX_COUNTER_VALUE = type(uint256).max - 1;
    
    /// @notice Maximum age of oracle data (seconds)
    uint32 public constant ORACLE_HEARTBEAT = 3600;
    
    /// @notice USDC decimals (used for internal accounting)
    uint8 public constant USD_DECIMALS = 6;
    
    /// @notice Minimum slippage tolerance (0.5%)
    uint256 public constant MIN_SLIPPAGE_BPS = 50;
    
    /// @notice Maximum slippage tolerance (5%)
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    
    /// @notice Denominator for basis points
    uint256 private constant BPS_DENOMINATOR = 10000;
    
    /// @notice Contract version
    string public constant VERSION = "3.0.1";
    
    // ======== IMMUTABLES ========
    
    /// @notice The USDC token contract
    IERC20 public immutable USDC;
    
    /// @notice Chainlink Aggregator for ETH/USD
    AggregatorV3Interface public immutable ETH_USD_FEED;
    
    /// @notice Decimals of the price feed
    uint8 public immutable FEED_DECIMALS;
    
    /// @notice Uniswap V2 Router
    IUniswapV2Router02 public immutable UNISWAP_ROUTER;
    
    /// @notice Max withdrawal per transaction in USD-6
    uint256 public immutable WITHDRAWAL_THRESHOLD_USD6;

    // ======== STORAGE ========
    
    /// @notice User balances in USD-6. Mapped by user => token => amount.
    /// @dev Only the USDC address key is used for storage in V3.
    mapping(address user => mapping(address token => uint256 usd6)) private s_balances;
    
    /// @notice Total bank balance in USD-6
    uint256 public s_totalUSD6;
    
    /// @notice Bank capacity limit in USD-6
    uint256 public s_bankCapUSD6;
    
    /// @notice Default slippage tolerance in Basis Points
    uint256 public s_defaultSlippageBps;
    
    /// @notice Counter for deposit operations
    uint256 public s_depositCount;
    
    /// @notice Counter for withdrawal operations
    uint256 public s_withdrawCount;
    
    /// @notice Counter for swap operations
    uint256 public s_swapCount;

    /*///////////////////////////
            EVENTS
    ///////////////////////////*/
    
    /**
     * @notice Emitted when a deposit occurs
     * @param user The user address
     * @param tokenIn The token deposited (address(0) for ETH)
     * @param amountIn The amount deposited
     * @param creditedUSD6 The amount of USDC credited
     */
    event Deposit(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 creditedUSD6
    );

    /**
     * @notice Emitted when a withdrawal occurs
     * @param user The user address
     * @param tokenOut The token withdrawn
     * @param debitedUSD6 The amount of USD-6 debited
     * @param amountTokenOut The amount of tokens sent
     */
    event Withdrawal(
        address indexed user,
        address indexed tokenOut,
        uint256 debitedUSD6,
        uint256 amountTokenOut
    );

    /// @notice Emitted when bank capacity is updated
    /// @param newCapUSD6 The new capacity
    event BankCapUpdated(uint256 newCapUSD6);
    
    /// @notice Emitted when default slippage is updated
    /// @param newSlippageBps The new slippage value
    event SlippageUpdated(uint256 newSlippageBps);

    /*///////////////////////////
           MODIFIERS
    ///////////////////////////*/
    
    /**
     * @notice Validates withdrawal parameters
     * @param token The token to withdraw
     * @param usd6Amount The amount in USD-6
     */
    modifier validateWithdrawal(address token, uint256 usd6Amount) {
        if (usd6Amount == 0) revert ZeroAmount();
        
        uint256 threshold = WITHDRAWAL_THRESHOLD_USD6;
        if (usd6Amount > threshold) {
            revert WithdrawalLimitExceeded(usd6Amount, threshold);
        }
        
        // In V3, we only store balance in USDC key
        uint256 userBalance = s_balances[msg.sender][address(USDC)];
        if (usd6Amount > userBalance) {
            revert InsufficientBalance(usd6Amount, userBalance);
        }
        _;
    }
    
    /**
     * @notice Validates counter overflow
     * @param counterType The counter type
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
     * @notice Initializes the contract
     * @param admin Admin address
     * @param usdc USDC address
     * @param ethUsdFeed Chainlink feed address
     * @param uniswapRouter Uniswap router address
     * @param bankCapUSD6 Initial capacity
     * @param withdrawalThresholdUSD6 Withdrawal limit
     * @param defaultSlippageBps Default slippage
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
        if (
            admin == address(0) ||
            usdc == address(0) ||
            ethUsdFeed == address(0) ||
            uniswapRouter == address(0)
        ) {
            revert InvalidParameters();
        }
        
        if (
            bankCapUSD6 == 0 ||
            withdrawalThresholdUSD6 == 0 ||
            withdrawalThresholdUSD6 > bankCapUSD6
        ) {
            revert InvalidParameters();
        }
        
        if (
            defaultSlippageBps < MIN_SLIPPAGE_BPS ||
            defaultSlippageBps > MAX_SLIPPAGE_BPS
        ) {
            revert InvalidSlippage();
        }
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(TREASURER_ROLE, admin);
        
        USDC = IERC20(usdc);
        ETH_USD_FEED = AggregatorV3Interface(ethUsdFeed);
        FEED_DECIMALS = ETH_USD_FEED.decimals();
        UNISWAP_ROUTER = IUniswapV2Router02(uniswapRouter);
        WITHDRAWAL_THRESHOLD_USD6 = withdrawalThresholdUSD6;
        
        s_bankCapUSD6 = bankCapUSD6;
        s_defaultSlippageBps = defaultSlippageBps;
    }

    /*///////////////////////////
      EXTERNAL FUNCTIONS - DEPOSITS
    ///////////////////////////*/
    
    /**
     * @notice Deposits ETH. Automatically swaps to USDC.
     * @dev Logic updated to store only USDC.
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
     * @notice Deposits USDC directly.
     * @param amountUSDC Amount to deposit
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
     * @notice Deposits an ERC20 token. Automatically swaps to USDC.
     * @param token Token address
     * @param amountToken Amount to deposit
     * @param minAmountOutUSDC User provided minimum output
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
        
        // Enforce the stricter slippage: either protocol's or user's
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
     * @notice Withdraws ETH. Swaps internal USDC balance back to ETH.
     * @param usd6Amount Amount of USD to withdraw
     */
    function withdrawETH(uint256 usd6Amount)
        external
        whenNotPaused
        nonReentrant
        validateWithdrawal(address(USDC), usd6Amount)
        validateCounter(CounterType.WITHDRAWAL)
    {
        _processWithdrawal(usd6Amount);

        USDC.forceApprove(address(UNISWAP_ROUTER), usd6Amount);
        
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = UNISWAP_ROUTER.WETH();
        
        try UNISWAP_ROUTER.swapExactTokensForETH(
            usd6Amount,
            0, // Market sell allowed on exit
            path,
            msg.sender,
            block.timestamp + 300
        ) returns (uint256[] memory amounts) {
             emit Withdrawal(msg.sender, address(0), usd6Amount, amounts[amounts.length - 1]);
        } catch {
            revert SwapFailed();
        }
    }
    
    /**
     * @notice Withdraws USDC.
     * @param usd6Amount Amount to withdraw
     */
    function withdrawUSDC(uint256 usd6Amount)
        external
        whenNotPaused
        nonReentrant
        validateWithdrawal(address(USDC), usd6Amount)
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
     * @notice Updates balance and checks cap
     * @param amountUSD6 Amount to add
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
     * @notice Updates balance for withdrawal
     * @param amountUSD6 Amount to subtract
     */
    function _processWithdrawal(uint256 amountUSD6) internal {
        unchecked {
            s_balances[msg.sender][address(USDC)] -= amountUSD6;
            s_totalUSD6 -= amountUSD6;
            s_withdrawCount++;
        }
    }
    
    /**
     * @notice Calculates minimum amount out based on slippage config
     * @param amountIn Input amount
     * @param path Swap path
     */
    function _calculateMinAmountOut(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        uint256[] memory amountsOut = UNISWAP_ROUTER.getAmountsOut(amountIn, path);
        uint256 expected = amountsOut[amountsOut.length - 1];
        return (expected * (BPS_DENOMINATOR - s_defaultSlippageBps)) / BPS_DENOMINATOR;
    }

    /*///////////////////////////
    EXTERNAL FUNCTIONS - ADMIN
    ///////////////////////////*/
    
    /**
     * @notice Sets new bank capacity
     * @param newCap New capacity
     */
    function setBankCapUSD6(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCap == 0) revert InvalidParameters();
        s_bankCapUSD6 = newCap;
        emit BankCapUpdated(newCap);
    }
    
    /**
     * @notice Sets default slippage
     * @param newSlippageBps New slippage in BPS
     */
    function setDefaultSlippage(uint256 newSlippageBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSlippageBps < MIN_SLIPPAGE_BPS || newSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippage();
        }
        s_defaultSlippageBps = newSlippageBps;
        emit SlippageUpdated(newSlippageBps);
    }
    
    /**
     * @notice Pauses the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Rescues tokens
     * @param token Token address
     * @param amount Amount to rescue
     */
    function rescue(address token, uint256 amount) external onlyRole(TREASURER_ROLE) {
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
     * @notice Gets user balance in USDC
     * @param user User address
     * @return Balance in USD-6
     */
    function getBalanceUSD6(address user) external view returns (uint256) {
        return s_balances[user][address(USDC)];
    }

    /**
     * @notice Gets current ETH price from Chainlink (for verification/frontend)
     * @return price The current price
     * @return decimals The price decimals
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
     * @notice Receive function to accept ETH from Uniswap Router only
     */
    receive() external payable {
        if (msg.sender != address(UNISWAP_ROUTER)) {
            revert UseDepositETH();
        }
    }
}