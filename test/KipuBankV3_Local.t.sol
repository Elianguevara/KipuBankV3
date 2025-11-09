// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockAggregator} from "./MockAggregator.sol";
import {MockRouterV2} from "./MockRouterV2.sol";

import {
    KBV3_ZeroAmount,
    KBV3_CapExceeded,
    KBV3_InsufficientBalance,
    KBV3_UnsupportedToken,
    KBV3_WithdrawalLimitExceeded
} from "../src/KipuBankV3.sol";


contract Receiver {
    receive() external payable {}
}

contract KipuBankV3_LocalTest is Test {
    KipuBankV3 public bank;

    address USDC;
    address admin = address(100);
    address user = address(new Receiver());
    address treasurer = address(200);
    address pauser = address(300);

    uint256 constant CAP = 1_000_000 * 1e6;  // 1M USD (debe ser mayor que threshold)
    uint256 constant WITHDRAW_THRESHOLD = 10_000 * 1e6;  // 10K USD

    function setUp() public {
        // Mock tokens and price feed
        ERC20Mock usdcMock = new ERC20Mock();
        USDC = address(usdcMock);
        
        // Create mock price feed with 8 decimals and initial price of 2000 USD
        MockAggregator mockFeed = new MockAggregator(8, 2000 * 1e8);
        
        // Create mock router
        MockRouterV2 mockRouter = new MockRouterV2(USDC);

        vm.deal(user, 100 ether);

        bank = new KipuBankV3(
            admin,
            USDC,
            address(mockFeed),
            address(mockRouter),
            CAP,
            WITHDRAW_THRESHOLD,
            100
        );

        vm.startPrank(admin);
        bank.grantRole(bank.TREASURER_ROLE(), treasurer);
        bank.grantRole(bank.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    function test_DepositETH_AccreditsUSD6_RespectsCap() public {
        vm.prank(user);
        bank.depositETH{value: 0.01 ether}();

        assertGt(bank.getBalanceUSD6(user, address(0)), 0);
    }

    function test_Revert_DepositETH_ZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(KBV3_ZeroAmount.selector);
        bank.depositETH{value: 0}();
    }

    function test_Revert_DepositETH_ExceedsCap() public {
    vm.prank(admin);
    bank.setBankCapUSD6(1000);

    vm.prank(user);
    vm.expectRevert();
    bank.depositETH{value: 1 ether}();
    }

    function test_DepositUSDC_1to1() public {
        deal(USDC, user, 500 * 1e6);

        vm.startPrank(user);
        IERC20(USDC).approve(address(bank), 500 * 1e6);
        bank.depositUSDC(500 * 1e6);
        vm.stopPrank();

        assertEq(bank.getBalanceUSD6(user, USDC), 500 * 1e6);
    }

    function test_Revert_DepositToken_USDCUnsupported() public {
        deal(USDC, user, 100 * 1e6);

        vm.startPrank(user);
        IERC20(USDC).approve(address(bank), 100 * 1e6);
        vm.expectRevert(KBV3_UnsupportedToken.selector);
        bank.depositToken(USDC, 100 * 1e6, 0);
        vm.stopPrank();
    }

    function test_Revert_Withdraw_InsufficientBalance() public {
    vm.prank(user);
    vm.expectRevert();
    bank.withdrawETH(1_000 * 1e6);
    }

    function test_Revert_Withdraw_ExceedsThreshold() public {
    vm.startPrank(user);
    bank.depositETH{value: 1 ether}();
    vm.stopPrank();

    uint256 tooMuch = WITHDRAW_THRESHOLD + 1;

    vm.prank(user);
    vm.expectRevert();
    bank.withdrawETH(tooMuch);
    }

    function test_WithdrawETH() public {
        vm.prank(user);
        bank.depositETH{value: 1 ether}();

        uint256 balance = bank.getBalanceUSD6(user, address(0));

        vm.prank(user);
        bank.withdrawETH(balance / 2);

        assertLt(bank.getBalanceUSD6(user, address(0)), balance);
    }

    function test_WithdrawUSDC() public {
        deal(USDC, user, 500 * 1e6);

        vm.startPrank(user);
        IERC20(USDC).approve(address(bank), 500 * 1e6);
        bank.depositUSDC(500 * 1e6);
        bank.withdrawUSDC(200 * 1e6);
        vm.stopPrank();

        assertEq(bank.getBalanceUSD6(user, USDC), 300 * 1e6);
    }

    function test_Pause_Unpause() public {
        vm.prank(pauser);
        bank.pause();

        vm.prank(user);
        vm.expectRevert();
        bank.depositETH{value: 1 ether}();

        vm.prank(pauser);
        bank.unpause();

        vm.prank(user);
        bank.depositETH{value: 0.1 ether}();
    }

    function test_Admin_UpdateCapAndSlippage() public {
        vm.prank(admin);
        bank.setBankCapUSD6(5000 * 1e6);
        assertEq(bank.s_bankCapUSD6(), 5000 * 1e6);

        vm.prank(admin);
        bank.setDefaultSlippage(150);
        assertEq(bank.s_defaultSlippageBps(), 150);
    }

    function test_Treasurer_RescueTokens() public {
        deal(USDC, address(bank), 100 * 1e6);

        uint256 before = IERC20(USDC).balanceOf(treasurer);

        vm.prank(treasurer);
        bank.rescue(USDC, 100 * 1e6);

        uint256 afterBal = IERC20(USDC).balanceOf(treasurer);
        assertEq(afterBal - before, 100 * 1e6);
    }

    function test_DepositToken_SwapsToUSDC() public {
        // Create test token and mock its price
        ERC20Mock token = new ERC20Mock();
        address tokenAddress = address(token);
        
        // Set token ratio in router (1 token = 2 USDC)
        MockRouterV2(address(bank.UNISWAP_ROUTER())).setRatio(tokenAddress, 2 * 1e6);

        // Give user some tokens
        deal(tokenAddress, user, 1000 * 1e18);

        vm.startPrank(user);
        token.approve(address(bank), 1000 * 1e18);
        
        // Mint USDC to router for swaps
        deal(USDC, address(bank.UNISWAP_ROUTER()), 10000 * 1e6);

        // Deposit should succeed now
        bank.depositToken(tokenAddress, 100 * 1e18, 0);
        
        // Check balances - should have received 200 USDC (100 tokens * 2 USDC per token)
        assertEq(bank.getBalanceUSD6(user, USDC), 200 * 1e6);
        vm.stopPrank();
    }
}
