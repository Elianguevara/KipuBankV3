// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Correct relative import for the mock
import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 public bank;
    MockV3Aggregator public mockOracle;
    
    // Sepolia Addresses
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant UNISWAP_ROUTER_SEPOLIA = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;

    address admin = makeAddr("admin");
    address user1 = makeAddr("user1");
    
    uint256 constant BANK_CAP = 1_000_000 * 1e6;
    uint256 constant WITHDRAW_THRESHOLD = 10_000 * 1e6;
    uint256 constant DEFAULT_SLIPPAGE = 100; // 1%

    // Events re-declared for testing expectations (using UpperCamelCase)
    event Deposit(address indexed user, address indexed token, uint256 amountIn, uint256 creditedUSD6);
    event Withdrawal(address indexed user, address indexed token, uint256 debitedUSD6, uint256 amountTokenSent);

    function setUp() public {
        // Setup Fork (only if RPC URL is available)
        try vm.envString("SEPOLIA_RPC_URL") returns (string memory rpc) {
             vm.createSelectFork(rpc);
        } catch {
             console.log("Warning: No SEPOLIA_RPC_URL found. Running with real Chainlink/Uniswap addresses but no active fork.");
        }

        // Deploy Mock Oracle
        mockOracle = new MockV3Aggregator(8, 2000e8); // Initial price: 2000 USD/ETH

        vm.startPrank(admin);
        bank = new KipuBankV3(
            admin,
            USDC_SEPOLIA,
            address(mockOracle), // Injected Mock Oracle
            UNISWAP_ROUTER_SEPOLIA,
            BANK_CAP,
            WITHDRAW_THRESHOLD,
            DEFAULT_SLIPPAGE
        );
        vm.stopPrank();
        
        vm.deal(user1, 10 ether);
    }

    /// @notice Test that depositing ETH automatically swaps to USDC (no ETH balance stored)
    function test_DepositETH_SwapsToUSDC() public {
        vm.startPrank(user1);
        
        uint256 amount = 0.01 ether;
        
        vm.expectEmit(true, true, false, false);
        emit Deposit(user1, address(0), amount, 0); 
        
        bank.depositETH{value: amount}();
        
        uint256 bal = bank.getBalanceUSD6(user1);
        assertGt(bal, 0, "Balance should be credited in USDC");
        assertEq(address(bank).balance, 0, "Bank should not hold ETH after swap");
        
        vm.stopPrank();
    }

    /// @notice Test Oracle Stale Price check (Crucial for Branch Coverage > 50%)
    function test_RevertWhen_OraclePriceIsStale() public {
        // ORACLE_HEARTBEAT is 3600 seconds. We warp time past that limit.
        vm.warp(block.timestamp + 4000); 
        
        vm.expectRevert(KipuBankV3.StalePrice.selector);
        bank.getETHPrice();
    }

    /// @notice Test Oracle Negative/Zero Price check (Crucial for Branch Coverage > 50%)
    function test_RevertWhen_OraclePriceIsNegative() public {
        // We force the mock to return an invalid price (<= 0)
        mockOracle.updateAnswer(-100);
        
        vm.expectRevert(KipuBankV3.OracleCompromised.selector);
        bank.getETHPrice();
    }

    // Add more tests here to increase coverage, such as ERC20 deposit, withdrawal limit checks, etc.

    function test_DepositUSDC() public {
        uint256 amount = 100 * 1e6;
        deal(USDC_SEPOLIA, user1, amount);
        
        vm.startPrank(user1);
        IERC20(USDC_SEPOLIA).approve(address(bank), amount);
        bank.depositUSDC(amount);
        assertEq(bank.getBalanceUSD6(user1), amount);
        vm.stopPrank();
    }
}