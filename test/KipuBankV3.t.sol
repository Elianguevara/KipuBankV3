// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";
import {MockUniswapRouter} from "./mocks/MockUniswapRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title KipuBankV3Test
 * @notice Test suite for the KipuBankV3 contract, covering all functionalities and security checks.
 */
contract KipuBankV3Test is Test {
    KipuBankV3 public bank;
    MockV3Aggregator public mockOracle;
    MockUniswapRouter public mockRouter;
    MockERC20 public mockToken;
    
    // Sepolia Addresses
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant WETH_SEPOLIA = 0x7B79995e5F4ADA581Ed0aeeEe8858D9d2Df3a83A; 
    
    address admin = vm.addr(100);
    address user1 = vm.addr(1);
    address user2 = vm.addr(2);
    address treasury = vm.addr(3);
    
    // Configuration Constants
    uint256 constant BANK_CAP = 1_000_000 * 1e6;
    uint256 constant WITHDRAW_THRESHOLD = 10_000 * 1e6;
    uint256 constant DEFAULT_SLIPPAGE = 100; 
    uint256 constant ETH_PRICE = 2000e8;

    // Events
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 creditedUSD6);
    event Withdrawal(address indexed user, address indexed tokenOut, uint256 debitedUSD6, uint256 amountTokenOut);
    event BankCapUpdated(uint256 newCapUSD6);
    event SlippageUpdated(uint256 newSlippageBps);

    function setUp() public {
        // Setup Fork
        try vm.envString("SEPOLIA_RPC_URL") returns (string memory rpc) {
             vm.createSelectFork(rpc);
        } catch {
             console.log("Warning: No SEPOLIA_RPC_URL found. Running with mocks.");
        }

        // Deploy Mocks
        mockOracle = new MockV3Aggregator(8, int256(ETH_PRICE)); 
        mockRouter = new MockUniswapRouter(WETH_SEPOLIA, USDC_SEPOLIA);
        mockToken = new MockERC20("Mock Token", "MTK", 18);

        vm.startPrank(admin);
        bank = new KipuBankV3(
            admin,
            USDC_SEPOLIA,
            address(mockOracle), 
            address(mockRouter),
            BANK_CAP,
            WITHDRAW_THRESHOLD,
            DEFAULT_SLIPPAGE
        );
        
        bank.grantRole(bank.TREASURER_ROLE(), treasury);
        vm.stopPrank();
        
        // Fund accounts
        vm.deal(user1, 10 ether);
        vm.deal(WETH_SEPOLIA, 10 ether);
        
        // Fund the mock router with USDC
        deal(USDC_SEPOLIA, address(mockRouter), 10_000_000 * 1e6);
    }
    
    // =========================================================================
    // CONSTRUCTOR COVERAGE
    // =========================================================================
    
    function test_Ctor_Revert_USDC_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, address(0), address(mockOracle), address(mockRouter), BANK_CAP, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }

    function test_Ctor_Revert_ETHFeed_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(0), address(mockRouter), BANK_CAP, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }
    
    function test_Ctor_Revert_Router_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(0), BANK_CAP, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }
    
    function test_Ctor_Revert_Cap_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(mockRouter), 0, WITHDRAW_THRESHOLD, DEFAULT_SLIPPAGE);
    }

    function test_Ctor_Revert_Threshold_Zero() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(mockRouter), BANK_CAP, 0, DEFAULT_SLIPPAGE);
    }
    
    function test_Ctor_Revert_Threshold_Exceeds_Cap() public {
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        new KipuBankV3(admin, USDC_SEPOLIA, address(mockOracle), address(mockRouter), WITHDRAW_THRESHOLD, WITHDRAW_THRESHOLD + 1, DEFAULT_SLIPPAGE);
    }

    // =========================================================================
    // DEPOSIT COVERAGE
    // =========================================================================

    function test_DepositETH_SwapsToUSDC() public {
        vm.startPrank(user1);
        uint256 amount = 1 ether;
        uint256 expectedUSD = 2000 * 1e6;
        
        mockRouter.setExpectedOutputAmount(expectedUSD);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, address(0), amount, expectedUSD); 
        
        bank.depositETH{value: amount}();
        
        assertEq(bank.getBalanceUSD6(user1), expectedUSD, "Balance should be credited in USDC");
        assertEq(address(bank).balance, 0, "Bank should not hold ETH after swap");
        
        vm.stopPrank();
    }

    function test_RevertWhen_DepositETH_SwapFails() public {
        vm.startPrank(user1);
        uint256 amount = 1 ether;
        
        mockRouter.setShouldSwapFail(true);
        
        vm.expectRevert(KipuBankV3.SwapFailed.selector);
        bank.depositETH{value: amount}();
        
        mockRouter.setShouldSwapFail(false);
        vm.stopPrank();
    }
    
    function test_DepositToken_Success() public {
        uint256 tokenAmount = 100 * 1e18;
        uint256 expectedUSD = 500 * 1e6;
        
        mockToken.mint(user1, tokenAmount);
        mockRouter.setExpectedOutputAmount(expectedUSD);

        vm.startPrank(user1);
        mockToken.approve(address(bank), tokenAmount);
        
        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, address(mockToken), tokenAmount, expectedUSD); 

        bank.depositToken(address(mockToken), tokenAmount, 0);
        
        assertEq(bank.getBalanceUSD6(user1), expectedUSD, "USDC balance must match");
        assertEq(mockToken.balanceOf(user1), 0, "User's token balance must be zero");
        vm.stopPrank();
    }
    
    function test_RevertWhen_DepositToken_SwapFails() public {
        uint256 tokenAmount = 100 * 1e18;
        mockToken.mint(user1, tokenAmount);
        
        vm.startPrank(user1);
        mockToken.approve(address(bank), tokenAmount);
        
        mockRouter.setShouldSwapFail(true);
        
        vm.expectRevert(KipuBankV3.SwapFailed.selector);
        bank.depositToken(address(mockToken), tokenAmount, 0); 
        
        mockRouter.setShouldSwapFail(false);
        vm.stopPrank();
    }
    
    function test_DepositToken_UsesStricterMinOut() public {
        uint256 tokenAmount = 100 * 1e18;
        uint256 userMinOut = 995 * 1e6;
        
        mockToken.mint(user1, tokenAmount);

        vm.startPrank(user1);
        mockToken.approve(address(bank), tokenAmount);
        
        // Configurar para que devuelva menos del mínimo del usuario
        mockRouter.setExpectedOutputAmount(994 * 1e6);
        
        // Debería revertir porque devuelve menos de lo que el usuario especificó
        vm.expectRevert();
        bank.depositToken(address(mockToken), tokenAmount, userMinOut); 
        
        vm.stopPrank();
    }

    function test_DepositUSDC() public {
        uint256 amount = 100 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount);
        assertEq(bank.getBalanceUSD6(user1), amount);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositUSDC_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositUSDC(0);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositUSDC_CapExceeded() public {
        uint256 requestedAmount = BANK_CAP + 1;
        
        deal(USDC_SEPOLIA, user1, requestedAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), requestedAmount);

        vm.expectRevert(abi.encodeWithSelector(
            KipuBankV3.CapExceeded.selector,
            requestedAmount,
            BANK_CAP
        ));
        
        bank.depositUSDC(requestedAmount);
        vm.stopPrank();
    }
    
    function test_RevertWhen_DepositToken_IsUSDC() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBankV3.UnsupportedToken.selector);
        bank.depositToken(USDC_SEPOLIA, 100, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositETH_ZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.depositETH{value: 0}();
        vm.stopPrank();
    }
    
    function test_RevertWhen_DirectETHTransfer() public {
        vm.expectRevert(KipuBankV3.UseDepositETH.selector);
        payable(address(bank)).transfer(0.1 ether);
    }

    function test_RevertWhen_Deposit_Paused() public {
        vm.startPrank(admin);
        bank.pause();
        vm.stopPrank();

        vm.startPrank(user1);
        deal(USDC_SEPOLIA, user1, 10 * 1e6);
        IERC20(USDC_SEPOLIA).approve(address(bank), 10 * 1e6);

        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("EnforcedPause()"))));
        bank.depositUSDC(10 * 1e6);
        vm.stopPrank();
    }

    // =========================================================================
    // WITHDRAWAL COVERAGE
    // =========================================================================

    function test_WithdrawUSDC() public {
        uint256 amount = 100 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount);
        
        vm.expectEmit(true, true, false, true);
        emit Withdrawal(user1, USDC_SEPOLIA, amount, amount);
        bank.withdrawUSDC(amount);
        
        assertEq(bank.getBalanceUSD6(user1), 0);
        vm.stopPrank();
    }

    function test_WithdrawETH_Success() public {
        uint256 usdAmount = 1000 * 1e6;
        uint256 expectedETH = 0.5 ether;
        
        deal(USDC_SEPOLIA, user1, usdAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), usdAmount);
        bank.depositUSDC(usdAmount);
        vm.stopPrank();
        
        vm.deal(address(mockRouter), 10 ether);
        mockRouter.setExpectedOutputAmount(expectedETH);
        
        uint256 initialETHBalance = user1.balance;
        
        vm.startPrank(user1);
        bank.withdrawETH(usdAmount);
        vm.stopPrank();
        
        assertEq(bank.getBalanceUSD6(user1), 0, "USDC balance should be 0");
        assertEq(user1.balance, initialETHBalance + expectedETH, "User should receive ETH");
    }

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

    function test_RevertWhen_WithdrawalZeroAmount() public {
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.withdrawUSDC(0);
    }
    
    function test_RevertWhen_WithdrawalExceedsThreshold() public {
        uint256 requestedAmount = WITHDRAW_THRESHOLD + 1;
        
        deal(USDC_SEPOLIA, user1, requestedAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), requestedAmount);
        bank.depositUSDC(requestedAmount); 
        
        vm.expectRevert(abi.encodeWithSelector(
            KipuBankV3.WithdrawalLimitExceeded.selector,
            requestedAmount,
            WITHDRAW_THRESHOLD
        ));
        
        bank.withdrawUSDC(requestedAmount);
        vm.stopPrank();
    }
    
    function test_RevertWhen_InsufficientBalance() public {
        uint256 depositedAmount = 50 * 1e6;
        uint256 requestedAmount = 100 * 1e6;

        deal(USDC_SEPOLIA, user1, depositedAmount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), depositedAmount);
        bank.depositUSDC(depositedAmount); 
        
        vm.expectRevert(abi.encodeWithSelector(
            KipuBankV3.InsufficientBalance.selector,
            requestedAmount,
            depositedAmount
        ));
        
        bank.withdrawUSDC(requestedAmount);
        vm.stopPrank();
    }
    
    // =========================================================================
    // ORACLE COVERAGE
    // =========================================================================

    function test_RevertWhen_OraclePriceIsStale() public {
        vm.warp(block.timestamp + 4000); 
        
        vm.expectRevert(KipuBankV3.StalePrice.selector);
        bank.getETHPrice();
    }

    function test_RevertWhen_OraclePriceIsNegative() public {
        mockOracle.updateAnswer(-100);
        
        vm.expectRevert(KipuBankV3.OracleCompromised.selector);
        bank.getETHPrice();
    }

    // =========================================================================
    // ADMIN FUNCTIONS COVERAGE
    // =========================================================================

    function test_Admin_SetBankCapUSD6() public {
        uint256 newCap = 5_000_000 * 1e6;
        
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true);
        emit BankCapUpdated(newCap);
        bank.setBankCapUSD6(newCap);
        assertEq(bank.s_bankCapUSD6(), newCap);
        vm.stopPrank();
    }

    function test_Admin_RevertWhen_SetBankCapUSD6_Zero() public {
        vm.startPrank(admin);
        vm.expectRevert(KipuBankV3.InvalidParameters.selector);
        bank.setBankCapUSD6(0);
        vm.stopPrank();
    }

    function test_Admin_SetDefaultSlippage() public {
        uint256 newSlippage = 200;
        
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true);
        emit SlippageUpdated(newSlippage);
        bank.setDefaultSlippage(newSlippage);
        assertEq(bank.s_defaultSlippageBps(), newSlippage);
        vm.stopPrank();
    }

    function test_Admin_RevertWhen_SetDefaultSlippage_TooLow() public {
        vm.startPrank(admin);
        vm.expectRevert(KipuBankV3.InvalidSlippage.selector);
        bank.setDefaultSlippage(49);
        vm.stopPrank();
    }

    function test_Admin_RevertWhen_SetDefaultSlippage_TooHigh() public {
        vm.startPrank(admin);
        vm.expectRevert(KipuBankV3.InvalidSlippage.selector);
        bank.setDefaultSlippage(501);
        vm.stopPrank();
    }

    // =========================================================================
    // PAUSABLE COVERAGE
    // =========================================================================

    function test_Admin_PauseAndUnpause() public {
        vm.startPrank(admin);
        bank.pause();
        assertTrue(bank.paused(), "Contract should be paused");
        
        bank.unpause();
        assertFalse(bank.paused(), "Contract should be unpaused");
        vm.stopPrank();
    }

    // =========================================================================
    // COUNTER OVERFLOW COVERAGE
    // =========================================================================

    function test_RevertWhen_DepositCounterOverflows() public {
        uint256 amount = 10 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount);
        vm.stopPrank();
        
        uint256 currentCount = bank.s_depositCount();
        assertEq(currentCount, 1, "Sanity check");
        
        for (uint256 i = 0; i < 100; i++) {
            bytes32 slot = bytes32(i);
            uint256 val = uint256(vm.load(address(bank), slot));
            if (val == 1) {
                vm.store(address(bank), slot, bytes32(uint256(2)));
                if (bank.s_depositCount() == 2) {
                    console.log("Deposit counter slot found at:", i);
                    vm.store(address(bank), slot, bytes32(bank.MAX_COUNTER_VALUE()));
                    
                    deal(USDC_SEPOLIA, user1, 10 * 1e6);
                    vm.startPrank(user1);
                    IERC20(USDC_SEPOLIA).approve(address(bank), 10 * 1e6);
                    
                    vm.expectRevert(KipuBankV3.CounterOverflow.selector);
                    bank.depositUSDC(10 * 1e6);
                    vm.stopPrank();
                    return;
                }
                vm.store(address(bank), slot, bytes32(uint256(1)));
            }
        }
        
        fail("Could not find deposit counter slot");
    }
    
    function test_RevertWhen_WithdrawalCounterOverflows() public {
        uint256 amount = 10 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount);
        bank.withdrawUSDC(amount / 2);
        vm.stopPrank();
        
        uint256 currentCount = bank.s_withdrawCount();
        assertEq(currentCount, 1, "Withdraw count should be 1");
        
        bool slotFound = false;
        for (uint256 i = 0; i < 50; i++) {
            bytes32 slot = bytes32(i);
            uint256 val = uint256(vm.load(address(bank), slot));
            
            if (val == 1) {
                vm.store(address(bank), slot, bytes32(uint256(2)));
                
                if (bank.s_withdrawCount() == 2) {
                    console.log("Withdrawal counter slot found at:", i);
                    vm.store(address(bank), slot, bytes32(bank.MAX_COUNTER_VALUE()));
                    assertEq(bank.s_withdrawCount(), bank.MAX_COUNTER_VALUE(), "Counter not set correctly");
                    
                    vm.startPrank(user1);
                    vm.expectRevert(KipuBankV3.CounterOverflow.selector);
                    bank.withdrawUSDC(amount / 2);
                    vm.stopPrank();
                    
                    slotFound = true;
                    break;
                }
                
                vm.store(address(bank), slot, bytes32(uint256(1)));
            }
        }
        
        assertTrue(slotFound, "Could not find withdrawal counter slot");
    }

    // =========================================================================
    // RESCUE COVERAGE
    // =========================================================================

    function test_Treasury_RescueETH() public {
        vm.deal(address(bank), 1 ether);
        uint256 initialTreasuryBalance = treasury.balance;
        uint256 rescueAmount = 0.5 ether;
        
        vm.startPrank(treasury);
        bank.rescue(address(0), rescueAmount);
        vm.stopPrank();
        
        assertEq(treasury.balance, initialTreasuryBalance + rescueAmount);
        assertEq(address(bank).balance, 0.5 ether);
    }

    function test_Treasury_RescueERC20() public {
        uint256 stuckAmount = 100 * 1e6;
        deal(USDC_SEPOLIA, address(bank), stuckAmount);
        
        uint256 initialTreasuryBalance = IERC20(USDC_SEPOLIA).balanceOf(treasury);
        
        vm.startPrank(treasury); 
        bank.rescue(USDC_SEPOLIA, stuckAmount);
        vm.stopPrank();
        
        assertEq(IERC20(USDC_SEPOLIA).balanceOf(treasury), initialTreasuryBalance + stuckAmount);
        assertEq(IERC20(USDC_SEPOLIA).balanceOf(address(bank)), 0);
    }

    function test_Treasury_RevertWhen_RescueZero() public {
        vm.startPrank(treasury);
        vm.expectRevert(KipuBankV3.ZeroAmount.selector);
        bank.rescue(address(0), 0);
        vm.stopPrank();
    }
}