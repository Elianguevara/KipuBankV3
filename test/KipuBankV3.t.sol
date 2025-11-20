// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {MockUniswapRouter} from "./mocks/MockUniswapRouter.sol"; // NEW IMPORT

/**
 * @title KipuBankV3Test
 * @notice Test suite for the KipuBankV3 contract, covering all functionalities and security checks.
 */
contract KipuBankV3Test is Test {
    KipuBankV3 public bank;
    MockV3Aggregator public mockOracle;
    MockUniswapRouter public mockRouter; // NEW Mock Router
    
    // Sepolia Addresses (Used only if forking, otherwise we mock)
    /// @notice Sepolia address for USDC (used as the contract's reserve currency).
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /// @notice Sepolia address for WETH (used for path definitions in swaps). Corrected EIP-55 checksum.
    address constant WETH_SEPOLIA = 0x7B79995e5F4ADA581Ed0aeeEe8858D9d2Df3a83A; 
    
    /// @notice Address of the contract administrator.
    address admin = makeAddr("admin");
    /// @notice Address of the first test user.
    address user1 = makeAddr("user1");
    /// @notice Address of the second test user.
    address user2 = makeAddr("user2");
    /// @notice Address designated as the treasury (for rescue function).
    address treasury = makeAddr("treasury");
    address unknownToken = makeAddr("unknownToken");
    
    // Configuration Constants (USD-6 decimals: 1e6)
    /// @notice Maximum total capacity of the bank in USD-6.
    uint256 constant BANK_CAP = 1_000_000 * 1e6;
    /// @notice Maximum withdrawal amount per transaction in USD-6.
    uint256 constant WITHDRAW_THRESHOLD = 10_000 * 1e6;
    /// @notice Default slippage tolerance (100 BPS = 1%).
    uint256 constant DEFAULT_SLIPPAGE = 100; 
    /// @notice Mock initial ETH price ($2000 with 8 decimals).
    uint256 constant ETH_PRICE = 2000e8; 

    // Events re-declared for testing expectations
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 creditedUSD6);
    event Withdrawal(address indexed user, address indexed tokenOut, uint256 debitedUSD6, uint256 amountTokenOut);
    event BankCapUpdated(uint256 newCapUSD6);
    event SlippageUpdated(uint256 newSlippageBps);

    /**
     * @notice Sets up the test environment.
     * @dev Deploys the MockV3Aggregator, MockUniswapRouter, and the KipuBankV3 contract, initializes users and roles.
     */
    function setUp() public {
        // Setup Fork (only if RPC URL is available)
        try vm.envString("SEPOLIA_RPC_URL") returns (string memory rpc) {
             vm.createSelectFork(rpc);
        } catch {
             console.log("Warning: No SEPOLIA_RPC_URL found. Running with mocks for router/tokens.");
        }

        // 1. Deploy Mocks
        mockOracle = new MockV3Aggregator(8, int256(ETH_PRICE)); 
        mockRouter = new MockUniswapRouter(WETH_SEPOLIA, USDC_SEPOLIA);

        vm.startPrank(admin);
        // 2. Deploy Contract (admin gets all initial roles inside the constructor)
        bank = new KipuBankV3(
            admin,
            USDC_SEPOLIA,
            address(mockOracle), 
            address(mockRouter), // Use mock router address
            BANK_CAP,
            WITHDRAW_THRESHOLD,
            DEFAULT_SLIPPAGE
        );
        
        // 4. Grant treasury role to the treasury address 
        bank.grantRole(bank.TREASURER_ROLE(), treasury);

        vm.stopPrank();
        
        // 3. Fund accounts and mock router with ETH/WETH for simulations
        vm.deal(user1, 10 ether);
        // Fund the router's WETH address to simulate reserves if needed, though the mock controls the output
        vm.deal(WETH_SEPOLIA, 10 ether); 
    }
    
    // =========================================================================
    // CONSTRUCTOR COVERAGE (InvalidParameters)
    // =========================================================================
    
    /// @notice Tests constructor reverts if USDC address is zero.
    function test_Ctor_Revert_USDC_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, address(0), address(mockOracle), address(mockRouter), BANK_CAP, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }

    /// @notice Tests constructor reverts if ETH price feed address is zero.
    function test_Ctor_Revert_ETHFeed_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(0), address(mockRouter), BANK_CAP, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }
    
    /// @notice Tests constructor reverts if Uniswap Router address is zero.
    function test_Ctor_Revert_Router_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(0), BANK_CAP, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }
    
    /// @notice Tests constructor reverts if bank capacity is zero.
    function test_Ctor_Revert_Cap_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(mockRouter), 0, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }

    /// @notice Tests constructor reverts if withdrawal threshold is zero.
    function test_Ctor_Revert_Threshold_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(mockRouter), BANK_CAP, 0, DEFAULT_SLIPPAGE);
    }
    
    /// @notice Tests constructor reverts if withdrawal threshold exceeds bank capacity.
    function test_Ctor_Revert_Threshold_Exceeds_Cap() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(mockRouter), WITHDRAW_THRESHOLD, WITHDRAW_THRESHOLD + 1, DEFAULT_SLIPPAGE);
    }

    // =========================================================================
    // DEPOSIT COVERAGE (DepositETH, DepositUSDC, DepositToken, CapExceeded)
    // =========================================================================

    /// @notice Tests a successful ETH deposit, which converts to USDC.
    function test_DepositETH_SwapsToUSDC() public {
        vm.startPrank(user1);
        uint256 amount = 1 ether;
        uint256 expectedUSD = 2000 * 1e6; // Mock output: 2000 USDC
        
        mockRouter.setExpectedOutputAmount(expectedUSD);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, address(0), amount, expectedUSD); 
        
        bank.depositETH{value: amount}();
        
        assertEq(bank.getBalanceUSD6(user1), expectedUSD, "Balance should be credited in USDC");
        assertEq(address(bank).balance, 0, "Bank should not hold ETH after swap");
        
        vm.stopPrank();
    }

    /// @notice Tests swapping ETH reverts if the Uniswap call fails.
    function test_RevertWhen_DepositETH_SwapFails() public {
        vm.startPrank(user1);
        uint256 amount = 1 ether;
        
        mockRouter.setShouldSwapFail(true);
        
        vm.expectRevert(KipuBankV3.SwapFailed.selector);
        bank.depositETH{value: amount}();
        
        mockRouter.setShouldSwapFail(false);
        vm.stopPrank();
    }
    
    /// @notice Tests a successful ERC20 deposit that converts to USDC.
    function test_DepositToken_Success() public {
        // Setup a mock token balance for user1 and for the router's expected output
        uint256 tokenAmount = 100 * 1e18;
        uint256 expectedUSD = 500 * 1e6; // Expected 500 USDC
        
        deal(unknownToken, user1, tokenAmount);
        mockRouter.setExpectedOutputAmount(expectedUSD);

        vm.startPrank(user1);
        IERC20(unknownToken).approve(address(bank), tokenAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, unknownToken, tokenAmount, expectedUSD); 

        bank.depositToken(unknownToken, tokenAmount, 0); // User provides 0 min out
        
        assertEq(bank.getBalanceUSD6(user1), expectedUSD, "USDC balance must match expected swap output");
        assertEq(IERC20(unknownToken).balanceOf(user1), 0, "User's token balance must be zero");
        vm.stopPrank();
    }
    
    /// @notice Tests depositToken reverts if the swap fails.
    function test_RevertWhen_DepositToken_SwapFails() public {
        uint256 tokenAmount = 100 * 1e18;
        deal(unknownToken, user1, tokenAmount);
        
        vm.startPrank(user1);
        IERC20(unknownToken).approve(address(bank), tokenAmount);
        
        mockRouter.setShouldSwapFail(true);
        
        vm.expectRevert(KipuBankV3.SwapFailed.selector);
        bank.depositToken(unknownToken, tokenAmount, 0); 
        
        mockRouter.setShouldSwapFail(false);
        vm.stopPrank();
    }
    
    /// @notice Tests that the stricter minimum output (user vs protocol) is used.
    function test_DepositToken_UsesStricterMinOut() public {
        uint256 tokenAmount = 100 * 1e18;
        // Mocked getAmountsOut returns 1000 USDC.
        uint256 protocolExpected = 1000 * 1e6; 
        // Protocol min out (1% slippage) = 990 USDC (990 * 1e6)
        
        // Scenario 1: User provides 995 USDC min out (stricter than protocol min)
        uint256 userMinOut = 995 * 1e6; 
        
        deal(unknownToken, user1, tokenAmount);
        mockRouter.setExpectedOutputAmount(protocolExpected);

        vm.startPrank(user1);
        IERC20(unknownToken).approve(address(bank), tokenAmount);
        
        // Set mock router to return less than 995 USDC (the stricter limit) to force failure
        mockRouter.setExpectedOutputAmount(994 * 1e6); 
        
        // This should revert because 994 USDC < 995 USDC
        vm.expectRevert(); // Swap should fail because 994 is less than the user's min of 995
        bank.depositToken(unknownToken, tokenAmount, userMinOut); 
        
        vm.stopPrank();
    }

    /// @notice Tests a standard USDC deposit.
    function test_DepositUSDC() public {
        uint256 amount = 100 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount);
        assertEq(bank.getBalanceUSD6(user1), amount);
        vm.stopPrank();
    }

    /// @notice Tests reverting when depositing zero USDC.
    function test_RevertWhen_DepositUSDC_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositUSDC(0);
        vm.stopPrank();
    }

    /// @notice Tests reverting when a deposit exceeds the bank's capacity.
    function test_RevertWhen_DepositUSDC_CapExceeded() public {
        // Requested amount is BANK_CAP + 1 USD-6
        uint256 requestedAmount = BANK_CAP + 1;
        
        deal(USDC_SEPOLIA, user1, requestedAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), requestedAmount);

        // Expect the CapExceeded error with the correct arguments
        vm.expectRevert(abi.encodeWithSelector(
            KipuBankV3.CapExceeded.selector,
            requestedAmount, // currentTotal (0) + amountUSD6
            BANK_CAP // maxCap
        ));
        
        bank.depositUSDC(requestedAmount);
        vm.stopPrank();
    }
    
    /// @notice Tests reverting if the user attempts to deposit USDC using the generic depositToken function.
    function test_RevertWhen_DepositToken_IsUSDC() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBankV3.UnsupportedToken.selector);
        bank.depositToken(USDC_SEPOLIA, 100, 0);
        vm.stopPrank();
    }

    /// @notice Tests reverting if the native ETH deposit amount is zero.
    function test_RevertWhen_DepositETH_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositETH{value: 0}();
        vm.stopPrank();
    }
    
    /// @notice Tests reverting if a direct ETH transfer is made (not via depositETH or Uniswap).
    function test_RevertWhen_DirectETHTransfer() public {
        vm.expectRevert(KipuBankV3.UseDepositETH.selector);
        (bool success,) = payable(address(bank)).call{value: 0.1 ether}("");
        assertFalse(success, "Direct ETH transfer should fail");
    }

    // =========================================================================
    // WITHDRAWAL COVERAGE (WithdrawalLimitExceeded, InsufficientBalance)
    // =========================================================================

    /// @notice Tests a standard USDC withdrawal.
    function test_WithdrawUSDC() public {
        // Setup: deposit
        uint256 amount = 100 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount);
        
        // Withdraw
        vm.expectEmit(true, true, false, true);
        emit Withdrawal(user1, USDC_SEPOLIA, amount, amount);
        bank.withdrawUSDC(amount);
        
        assertEq(bank.getBalanceUSD6(user1), 0);
        vm.stopPrank();
    }

    /// @notice Tests a successful ETH withdrawal, which converts USDC back to ETH.
    function test_WithdrawETH_Success() public {
        uint256 usdAmount = 1000 * 1e6; // 1000 USDC to withdraw
        uint256 expectedETH = 0.5 ether;
        
        // Setup: Deposit USDC and configure mock router
        deal(USDC_SEPOLIA, user1, usdAmount);
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), usdAmount);
        bank.depositUSDC(usdAmount);
        vm.stopPrank();
        
        uint256 initialETHBalance = user1.balance;
        mockRouter.setExpectedOutputAmount(expectedETH); // Mock the ETH output
        
        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit Withdrawal(user1, address(0), usdAmount, expectedETH);
        bank.withdrawETH(usdAmount);
        vm.stopPrank();
        
        // Assertions
        assertEq(bank.getBalanceUSD6(user1), 0, "USDC balance should be debited");
        assertEq(user1.balance, initialETHBalance + expectedETH, "ETH balance should reflect swap output");
    }

    /// @notice Tests reverting when the USDC to ETH swap fails during withdrawal.
    function test_RevertWhen_WithdrawETH_SwapFails() public {
        uint256 usdAmount = 100 * 1e6;
        deal(USDC_SEPOLIA, user1, usdAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), usdAmount);
        bank.depositUSDC(usdAmount);
        
        mockRouter.setShouldSwapFail(true);
        
        vm.expectRevert(KipuBankV3.SwapFailed.selector);
        bank.withdrawETH(usdAmount);
        
        mockRouter.setShouldSwapFail(false);
        vm.stopPrank();
    }

    /// @notice Tests reverting when withdrawing zero amount.
    function test_RevertWhen_WithdrawalZeroAmount() public {
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.withdrawUSDC(0);
    }
    
    /// @notice Tests reverting if the withdrawal amount exceeds the per-transaction limit.
    function test_RevertWhen_WithdrawalExceedsThreshold() public {
        // 1. Determine the amount that exceeds the limit
        uint256 requestedAmount = WITHDRAW_THRESHOLD + 1;
        
        // 2. Setup: Deposit enough to ensure balance check passes
        deal(USDC_SEPOLIA, user1, requestedAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), requestedAmount);
        bank.depositUSDC(requestedAmount); 
        
        // 3. Expect the revert with the correct arguments
        vm.expectRevert(abi.encodeWithSelector(
            KipuBankV3.WithdrawalLimitExceeded.selector,
            requestedAmount,
            WITHDRAW_THRESHOLD
        ));
        
        bank.withdrawUSDC(requestedAmount);
        vm.stopPrank();
    }
    
    /// @notice Tests reverting if the withdrawal amount exceeds the user's available balance.
    function test_RevertWhen_InsufficientBalance() public {
        // Deposited amount
        uint256 depositedAmount = 50 * 1e6;
        // Requested amount (higher)
        uint256 requestedAmount = 100 * 1e6;

        // Setup: Deposit less than the requested amount
        deal(USDC_SEPOLIA, user1, depositedAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), depositedAmount);
        bank.depositUSDC(depositedAmount); 
        
        // Expect the revert with the correct arguments
        vm.expectRevert(abi.encodeWithSelector(
            KipuBankV3.InsufficientBalance.selector,
            requestedAmount,
            depositedAmount
        ));
        
        bank.withdrawUSDC(requestedAmount);
        vm.stopPrank();
    }
    
    // =========================================================================
    // ORACLE COVERAGE (OracleCompromised, StalePrice)
    // =========================================================================

    /// @notice Tests reverting if the oracle price data is stale.
    function test_RevertWhen_OraclePriceIsStale() public {
        // ORACLE_HEARTBEAT is 3600 seconds. Warp time past the limit.
        vm.warp(block.timestamp + 4000); 
        
        vm.expectRevert(KipuBankV3.StalePrice.selector);
        bank.getETHPrice();
    }

    /// @notice Tests reverting if the oracle price is negative or zero.
    function test_RevertWhen_OraclePriceIsNegative() public {
        // Force the mock to return an invalid price (<= 0)
        mockOracle.updateAnswer(-100);
        
        vm.expectRevert(KipuBankV3.OracleCompromised.selector);
        bank.getETHPrice();
    }

    // =========================================================================
    // ADMIN FUNCTIONS COVERAGE (setBankCap, setDefaultSlippage)
    // =========================================================================

    /// @notice Tests successful update of the bank's capacity.
    function test_Admin_SetBankCapUSD6() public {
        uint256 newCap = 5_000_000 * 1e6;
        
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true);
        emit BankCapUpdated(newCap);
        bank.setBankCapUSD6(newCap);
        assertEq(bank.s_bankCapUSD6(), newCap);
        vm.stopPrank();
    }

    /// @notice Tests reverting if the new bank capacity is set to zero.
    function test_Admin_RevertWhen_SetBankCapUSD6_Zero() public {
        vm.startPrank(admin);
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        bank.setBankCapUSD6(0);
        vm.stopPrank();
    }

    /// @notice Tests successful update of the default slippage.
    function test_Admin_SetDefaultSlippage() public {
        uint256 newSlippage = 200; // 2%
        
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true);
        emit SlippageUpdated(newSlippage);
        bank.setDefaultSlippage(newSlippage);
        assertEq(bank.s_defaultSlippageBps(), newSlippage);
        vm.stopPrank();
    }

    /// @notice Tests reverting if the slippage is set below the minimum.
    function test_Admin_RevertWhen_SetDefaultSlippage_TooLow() public {
        vm.startPrank(admin);
        vm.expectRevert(KipuBankV3.InvalidSlippage.selector);
        bank.setDefaultSlippage(49); // Minimum is 50
        vm.stopPrank();
    }

    /// @notice Tests reverting if the slippage is set above the maximum.
    function test_Admin_RevertWhen_SetDefaultSlippage_TooHigh() public {
        vm.startPrank(admin);
        vm.expectRevert(KipuBankV3.InvalidSlippage.selector);
        bank.setDefaultSlippage(501); // Maximum is 500
        vm.stopPrank();
    }

    // =========================================================================
    // PAUSABLE COVERAGE
    // =========================================================================

    /// @notice Tests pausing and unpausing the contract successfully.
    function test_Admin_PauseAndUnpause() public {
        vm.startPrank(admin);
        bank.pause();
        assertTrue(bank.paused(), "Contract should be paused");
        
        bank.unpause();
        assertFalse(bank.paused(), "Contract should be unpaused");
        vm.stopPrank();
    }

    /// @notice Tests reverting a deposit when the contract is paused.
    function test_RevertWhen_Deposit_Paused() public {
        vm.startPrank(admin);
        bank.pause();
        vm.stopPrank();

        vm.startPrank(user1);
        deal(USDC_SEPOLIA, user1, 10 * 1e6);
        IERC20(USDC_SEPOLIA).approve(address(bank), 10 * 1e6);

        // FIX: Expecting the custom error EnforcedPause() from OpenZeppelin Pausable library
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("EnforcedPause()"))));

        bank.depositUSDC(10 * 1e6);
        vm.stopPrank();
    }

    // =========================================================================
    // COUNTER OVERFLOW COVERAGE
    // =========================================================================

    /// @notice Tests reverting if the deposit counter overflows.
    function test_RevertWhen_DepositCounterOverflows() public {
        vm.startPrank(admin);
        // Force the counter to the max safe value (type(uint256).max - 2)
        // Note: MAX_COUNTER_VALUE - 1 is type(uint256).max - 2
        vm.store(address(bank), bytes32(uint256(7)), bytes32(type(uint256).max - 2));
        vm.stopPrank();
        
        vm.startPrank(user1);
        deal(USDC_SEPOLIA, user1, 10 * 1e6);
        IERC20(USDC_SEPOLIA).approve(address(bank), 10 * 1e6);
        
        vm.expectRevert(KipuBankV3.CounterOverflow.selector);
        // This deposit would increment the counter past the safe max value
        bank.depositUSDC(10 * 1e6);
        vm.stopPrank();
    }
    
    /// @notice Tests reverting if the withdrawal counter overflows.
    function test_RevertWhen_WithdrawalCounterOverflows() public {
        uint256 amount = 10 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount); // Deposit to have balance
        vm.stopPrank();

        vm.startPrank(admin);
        // Force the withdrawal counter to the max safe value (slot 8)
        vm.store(address(bank), bytes32(uint256(8)), bytes32(type(uint256).max - 2));
        vm.stopPrank();
        
        vm.startPrank(user1);
        vm.expectRevert(KipuBankV3.CounterOverflow.selector);
        bank.withdrawUSDC(amount);
        vm.stopPrank();
    }
    
    /// @notice Tests reverting if the swap counter overflows during a deposit.
    function test_RevertWhen_SwapCounterOverflows() public {
        vm.startPrank(admin);
        // Force the swap counter to the max safe value (slot 9)
        vm.store(address(bank), bytes32(uint256(9)), bytes32(type(uint256).max - 2));
        vm.stopPrank();
        
        vm.startPrank(user1);
        uint256 amount = 1 ether;
        
        vm.expectRevert(KipuBankV3.CounterOverflow.selector);
        bank.depositETH{value: amount}();
        vm.stopPrank();
    }


    // =========================================================================
    // RESCUE COVERAGE (Treasury Role)
    // =========================================================================

    /// @notice Tests successful rescue of native ETH by the Treasurer.
    function test_Treasury_RescueETH() public {
        // Send ETH to the contract (simulating stuck funds)
        vm.deal(address(bank), 1 ether);
        uint256 initialTreasuryBalance = treasury.balance;
        uint256 rescueAmount = 0.5 ether;
        
        vm.startPrank(treasury); // Treasurer (with TREASURER_ROLE)
        bank.rescue(address(0), rescueAmount);
        vm.stopPrank();
        
        // Check balances after rescue
        assertEq(treasury.balance, initialTreasuryBalance + rescueAmount, "Treasury ETH balance mismatch");
        assertEq(address(bank).balance, 0.5 ether, "Bank ETH balance mismatch");
    }
    
    /// @notice Tests reverting if ETH transfer fails during rescue.
    function test_RevertWhen_RescueETH_TransferFails() public {
        // Send ETH to the contract
        vm.deal(address(bank), 1 ether);
        
        // Mock the ETH transfer call to fail using vm.mockCall
        vm.mockCall(
            address(treasury), 
            abi.encodeWithSignature("call()"), 
            abi.encode(false) // Encode return value false
        );
        
        vm.startPrank(treasury);
        vm.expectRevert(KipuBankV3.ETHTransferFailed.selector);
        bank.rescue(address(0), 0.5 ether);
        vm.stopPrank();
    }

    /// @notice Tests successful rescue of ERC20 tokens (USDC) by the Treasurer.
    function test_Treasury_RescueERC20() public {
        // Send USDC to the contract (simulating stuck funds)
        uint256 stuckAmount = 100 * 1e6;
        deal(USDC_SEPOLIA, address(bank), stuckAmount);
        
        uint256 initialTreasuryBalance = IERC20(USDC_SEPOLIA).balanceOf(treasury);
        
        vm.startPrank(treasury); 
        bank.rescue(USDC_SEPOLIA, stuckAmount);
        vm.stopPrank();
        
        // Check balances after rescue
        assertEq(IERC20(USDC_SEPOLIA).balanceOf(treasury), initialTreasuryBalance + stuckAmount, "Treasury USDC balance mismatch");
        assertEq(IERC20(USDC_SEPOLIA).balanceOf(address(bank)), 0, "Bank USDC balance mismatch");
    }

    /// @notice Tests reverting if the treasurer tries to rescue zero amount.
    function test_Treasury_RevertWhen_RescueZero() public {
        vm.startPrank(treasury);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.rescue(address(0), 0);
        vm.stopPrank();
    }
}