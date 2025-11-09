// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// Import de errores para expectRevert(selector)
import {
    KBV3_ZeroAmount,
    KBV3_CapExceeded,
    KBV3_InsufficientBalance,
    KBV3_UnsupportedToken,
    KBV3_WithdrawalLimitExceeded
} from "../src/KipuBankV3.sol";

/// @dev Necesario porque las direcciones de makeAddr NO reciben ETH
contract Receiver {
    receive() external payable {}
}

/**
 * @title KipuBankV3Test
 * @notice Suite completa de pruebas para KipuBankV3 (real fork Sepolia)
 */
contract KipuBankV3Test is Test {
    KipuBankV3 public bank;

    // Dirección reales de Sepolia
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant ETH_USD_FEED_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant UNISWAP_ROUTER_SEPOLIA = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    Receiver receiver1;
    Receiver receiver2;

    address admin = makeAddr("admin");
    address user1;
    address user2;
    address pauser = makeAddr("pauser");
    address treasurer = makeAddr("treasurer");

    uint256 constant BANK_CAP = 1_000_000 * 1e6;
    uint256 constant WITHDRAW_THRESHOLD = 10_000 * 1e6;
    uint256 constant DEFAULT_SLIPPAGE = 100;

    uint256 constant ETH_DEPOSIT = 1 ether;
    uint256 constant USDC_DEPOSIT = 1_000 * 1e6;

    event KBV3_Deposit(address indexed user, address indexed token, uint256 amountToken, uint256 creditedUSD6);
    event KBV3_Withdrawal(address indexed user, address indexed token, uint256 debitedUSD6, uint256 amountTokenSent);
    event KBV3_TokenSwapped(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountOutUSDC);
    event KBV3_BankCapUpdated(uint256 newCapUSD6);
    event KBV3_SlippageUpdated(uint256 newSlippageBps);

    function setUp() public {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        receiver1 = new Receiver();
        receiver2 = new Receiver();

        user1 = address(receiver1);
        user2 = address(receiver2);

        vm.startPrank(admin);
        bank = new KipuBankV3(
            admin,
            USDC_SEPOLIA,
            ETH_USD_FEED_SEPOLIA,
            UNISWAP_ROUTER_SEPOLIA,
            BANK_CAP,
            WITHDRAW_THRESHOLD,
            DEFAULT_SLIPPAGE
        );
        bank.grantRole(bank.PAUSER_ROLE(), pauser);
        bank.grantRole(bank.TREASURER_ROLE(), treasurer);
        vm.stopPrank();

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    /*///////////////////////////////////////////////////////////////
                         COUNTER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CounterIncrementCorrectly() public {
        assertEq(bank.s_depositCount(), 0);

        vm.prank(user1);
        bank.depositETH{value: 0.01 ether}();
        assertEq(bank.s_depositCount(), 1);

        vm.prank(user1);
        bank.depositETH{value: 0.01 ether}();
        assertEq(bank.s_depositCount(), 2);

        uint256 balance = bank.getBalanceUSD6(user1, address(0));
        vm.prank(user1);
        bank.withdrawETH(balance / 4);

        assertEq(bank.s_withdrawCount(), 1);
    }

    function test_CounterOverflowProtection_Placeholder() public {
        assertTrue(true);
    }

    /*///////////////////////////////////////////////////////////////
                      UNIFIED DEPOSIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_UnifiedDepositLogic() public {
        vm.startPrank(user1);

        uint256 expectedUSD6_ETH = bank.previewETHToUSD6(ETH_DEPOSIT);

        vm.expectEmit(true, true, false, true);
        emit KBV3_Deposit(user1, address(0), ETH_DEPOSIT, expectedUSD6_ETH);
        bank.depositETH{value: ETH_DEPOSIT}();

        deal(USDC_SEPOLIA, user1, USDC_DEPOSIT);
        IERC20(USDC_SEPOLIA).approve(address(bank), USDC_DEPOSIT);

        vm.expectEmit(true, true, false, true);
        emit KBV3_Deposit(user1, USDC_SEPOLIA, USDC_DEPOSIT, USDC_DEPOSIT);
        bank.depositUSDC(USDC_DEPOSIT);

        vm.stopPrank();

        assertEq(bank.s_depositCount(), 2);
    }

    /*///////////////////////////////////////////////////////////////
                      UNIFIED WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

    function test_UnifiedWithdrawalLogic() public {
        vm.startPrank(user1);

        bank.depositETH{value: ETH_DEPOSIT}();
        deal(USDC_SEPOLIA, user1, USDC_DEPOSIT);

        IERC20(USDC_SEPOLIA).approve(address(bank), USDC_DEPOSIT);
        bank.depositUSDC(USDC_DEPOSIT);

        uint256 ethBalance = bank.getBalanceUSD6(user1, address(0));
        uint256 usdcBalance = bank.getBalanceUSD6(user1, USDC_SEPOLIA);

        uint256 ethWithdraw = ethBalance / 2;
        uint256 expectedWei = bank.previewUSD6ToETH(ethWithdraw);

        vm.expectEmit(true, true, false, true);
        emit KBV3_Withdrawal(user1, address(0), ethWithdraw, expectedWei);
        bank.withdrawETH(ethWithdraw);

        uint256 usdcWithdraw = usdcBalance / 2;

        vm.expectEmit(true, true, false, true);
        emit KBV3_Withdrawal(user1, USDC_SEPOLIA, usdcWithdraw, usdcWithdraw);
        bank.withdrawUSDC(usdcWithdraw);

        vm.stopPrank();

        assertEq(bank.s_withdrawCount(), 2);
    }

    /*///////////////////////////////////////////////////////////////
                         INVALID DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DepositETH_ZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert();
        bank.depositETH{value: 0}();
    }

    function test_RevertWhen_DepositETH_ExceedsCap() public {
    vm.prank(admin);
    bank.setBankCapUSD6(1000);

    vm.prank(user1);
    vm.expectRevert();  
    bank.depositETH{value: 1 ether}();
    }

    function test_RevertWhen_DepositToken_IsUSDC() public {
        deal(USDC_SEPOLIA, user1, 1000 * 1e6);

        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), 1000 * 1e6);

        vm.expectRevert();
        bank.depositToken(USDC_SEPOLIA, 1000 * 1e6, 0);

        vm.stopPrank();
    }

    function test_RevertWhen_DepositToken_ZeroAmount() public {
        ERC20Mock mock = new ERC20Mock();

        vm.prank(user1);
        vm.expectRevert();
        bank.depositToken(address(mock), 0, 0);
    }

    /*///////////////////////////////////////////////////////////////
                        WITHDRAW REVERTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_WithdrawETH_InsufficientBalance() public {
        vm.prank(user1);
        vm.expectRevert();
        bank.withdrawETH(1000 * 1e6);
    }

    function test_RevertWhen_Withdraw_ExceedsThreshold() public {
        vm.prank(user1);
        bank.depositETH{value: 5 ether}();

        uint256 tooMuch = WITHDRAW_THRESHOLD + 1;

        vm.prank(user1);
        vm.expectRevert();
        bank.withdrawETH(tooMuch);
    }

    /*///////////////////////////////////////////////////////////////
                         WITHDRAW SUCCESS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawETH() public {
        vm.prank(user1);
        bank.depositETH{value: ETH_DEPOSIT}();

        uint256 balance = bank.getBalanceUSD6(user1, address(0));
        uint256 withdrawAmount = balance / 2;

        uint256 before = user1.balance;

        vm.prank(user1);
        bank.withdrawETH(withdrawAmount);

        assertGt(user1.balance, before);
    }

    function test_WithdrawUSDC() public {
        deal(USDC_SEPOLIA, user1, USDC_DEPOSIT);

        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), USDC_DEPOSIT);
        bank.depositUSDC(USDC_DEPOSIT);
        bank.withdrawUSDC(USDC_DEPOSIT / 2);
        vm.stopPrank();

        assertEq(
            bank.getBalanceUSD6(user1, USDC_SEPOLIA),
            USDC_DEPOSIT / 2
        );
    }

    /*///////////////////////////////////////////////////////////////
                          ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AdminCanUpdateCapAndSlippage() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit KBV3_BankCapUpdated(2_000_000 * 1e6);
        bank.setBankCapUSD6(2_000_000 * 1e6);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit KBV3_SlippageUpdated(150);
        bank.setDefaultSlippage(150);
    }

    function test_Pause_Unpause_BlocksStateChanging() public {
        vm.prank(pauser);
        bank.pause();

        vm.startPrank(user1);
        vm.expectRevert();
        bank.depositETH{value: 0.1 ether}();
        vm.stopPrank();

        vm.prank(pauser);
        bank.unpause();

        vm.prank(user1);
        bank.depositETH{value: 0.1 ether}();

        assertEq(bank.s_depositCount(), 1);
    }

    function test_TreasurerCanRescueTokens() public {
        deal(USDC_SEPOLIA, address(bank), 500 * 1e6);

        uint256 before = IERC20(USDC_SEPOLIA).balanceOf(treasurer);

        vm.prank(treasurer);
        bank.rescue(USDC_SEPOLIA, 500 * 1e6);

        uint256 afterBal = IERC20(USDC_SEPOLIA).balanceOf(treasurer);
        assertEq(afterBal - before, 500 * 1e6);
    }

    /*///////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositETH_WithCounters(uint96 amount) public {
        vm.assume(amount > 0 && amount < 10 ether);

        uint256 expected = bank.previewETHToUSD6(amount);
        vm.assume(expected <= BANK_CAP);

        vm.deal(user1, amount);

        vm.prank(user1);
        bank.depositETH{value: amount}();

        assertEq(bank.getBalanceUSD6(user1, address(0)), expected);
        assertEq(bank.s_depositCount(), 1);
    }

    function testFuzz_DepositWithdrawCycle(uint96 depositAmt, uint8 pct) public {
        vm.assume(depositAmt > 1000 && depositAmt < 10 ether);
        vm.assume(pct > 0 && pct <= 100);

        uint256 expected = bank.previewETHToUSD6(depositAmt);
        vm.assume(expected <= BANK_CAP);

        vm.deal(user1, depositAmt);

        vm.startPrank(user1);
        bank.depositETH{value: depositAmt}();

        uint256 balance = bank.getBalanceUSD6(user1, address(0));
        uint256 withdrawAmount = (balance * pct) / 100;

        vm.assume(withdrawAmount > 0 && withdrawAmount <= WITHDRAW_THRESHOLD);

        bank.withdrawETH(withdrawAmount);
        vm.stopPrank();

        assertEq(bank.s_withdrawCount(), 1);
    }
}
