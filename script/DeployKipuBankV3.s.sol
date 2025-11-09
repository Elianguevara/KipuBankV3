// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";

/**
 * @title DeployKipuBankV3
 * @notice Deployment script for KipuBankV3 contract on Sepolia testnet
 * @dev Usage:
 *      forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
 *        --rpc-url $SEPOLIA_RPC_URL \
 *        --broadcast \
 *        --verify \
 *        -vvvv
 * 
 * @author Elian Guevara
 */
contract DeployKipuBankV3 is Script {
    // ========================================
    // SEPOLIA TESTNET ADDRESSES
    // ========================================
    
    /// @notice USDC token on Sepolia (6 decimals)
    address constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    
    /// @notice Chainlink ETH/USD price feed on Sepolia
    address constant ETH_USD_FEED_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    
    /// @notice Uniswap V2 Router02 on Sepolia
    address constant UNISWAP_ROUTER_SEPOLIA = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;
    
    // ========================================
    // DEFAULT CONFIGURATION
    // ========================================
    
    /// @notice Default bank capacity: 1 Million USD (in USD-6)
    uint256 constant DEFAULT_BANK_CAP = 1_000_000 * 1e6;
    
    /// @notice Default withdrawal threshold: 10,000 USD (in USD-6)
    uint256 constant DEFAULT_WITHDRAWAL_THRESHOLD = 10_000 * 1e6;
    
    /// @notice Default slippage tolerance: 1% (100 basis points)
    uint256 constant DEFAULT_SLIPPAGE = 100;

    /**
     * @notice Main deployment function
     * @dev Deploys KipuBankV3 with default configuration for Sepolia testnet
     * @return bank Deployed KipuBankV3 contract instance
     */
    function run() external returns (KipuBankV3) {
        // Get deployer address from private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Display pre-deployment information
        _logPreDeployment(deployer);
        
        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy KipuBankV3
        KipuBankV3 bank = new KipuBankV3(
            deployer, // admin
            USDC_SEPOLIA,
            ETH_USD_FEED_SEPOLIA,
            UNISWAP_ROUTER_SEPOLIA,
            DEFAULT_BANK_CAP,
            DEFAULT_WITHDRAWAL_THRESHOLD,
            DEFAULT_SLIPPAGE
        );
        
        // Stop broadcasting
        vm.stopBroadcast();
        
        // Display post-deployment information
        _logPostDeployment(bank, deployer);
        
        return bank;
    }

    /**
     * @notice Logs pre-deployment information
     * @param deployer Address of the deployer
     */
    function _logPreDeployment(address deployer) private view {
        console.log("===========================================");
        console.log("PRE-DEPLOYMENT CHECK");
        console.log("===========================================");
        console.log("Network: Sepolia Testnet");
        console.log("Chain ID: 11155111");
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance, "wei");
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");
        console.log("");
        console.log("Configuration:");
        console.log("  USDC:", USDC_SEPOLIA);
        console.log("  ETH/USD Feed:", ETH_USD_FEED_SEPOLIA);
        console.log("  Uniswap Router:", UNISWAP_ROUTER_SEPOLIA);
        console.log("  Bank Cap:", DEFAULT_BANK_CAP, "USD-6");
        console.log("  Withdrawal Threshold:", DEFAULT_WITHDRAWAL_THRESHOLD, "USD-6");
        console.log("  Default Slippage:", DEFAULT_SLIPPAGE, "bps");
        console.log("===========================================");
        console.log("");
    }

    /**
     * @notice Logs post-deployment information
     * @param bank Deployed KipuBankV3 instance
     * @param deployer Address of the deployer
     */
    function _logPostDeployment(KipuBankV3 bank, address deployer) private view {
        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("Contract Address:", address(bank));
        console.log("===========================================");
        console.log("");
        console.log("Contract Details:");
        console.log("  Version:", bank.VERSION());
        console.log("  USDC:", address(bank.USDC()));
        console.log("  ETH/USD Feed:", address(bank.ETH_USD_FEED()));
        console.log("  Uniswap Router:", address(bank.UNISWAP_ROUTER()));
        console.log("  Bank Cap:", bank.s_bankCapUSD6(), "USD-6");
        console.log("  Withdrawal Threshold:", bank.WITHDRAWAL_THRESHOLD_USD6(), "USD-6");
        console.log("  Default Slippage:", bank.s_defaultSlippageBps(), "bps");
        console.log("");
        console.log("Roles Configuration:");
        console.log("  Admin:", deployer);
        console.log("  - DEFAULT_ADMIN_ROLE: true");
        console.log("  - PAUSER_ROLE: true");
        console.log("  - TREASURER_ROLE: true");
        console.log("");
        console.log("===========================================");
        console.log("NEXT STEPS");
        console.log("===========================================");
        console.log("1. Verify contract on Etherscan:");
        console.log("   https://sepolia.etherscan.io/address/", address(bank));
        console.log("");
        console.log("2. Test deposit ETH:");
        console.log("   cast send", address(bank), '"depositETH()" \\');
        console.log("     --value 0.01ether \\");
        console.log("     --private-key $PRIVATE_KEY \\");
        console.log("     --rpc-url $SEPOLIA_RPC_URL");
        console.log("");
        console.log("3. Check your balance:");
        console.log("   cast call", address(bank), '"getBalanceUSD6(address,address)(uint256)" \\');
        console.log("    ", deployer, "\\");
        console.log("     0x0000000000000000000000000000000000000000 \\");
        console.log("     --rpc-url $SEPOLIA_RPC_URL");
        console.log("");
        console.log("4. Manual verification (if auto-verify failed):");
        console.log("   forge verify-contract \\");
        console.log("     --chain-id 11155111 \\");
        console.log("     --compiler-version v0.8.26+commit.8a97fa7a \\");
        console.log("    ", address(bank), "\\");
        console.log("     src/KipuBankV3.sol:KipuBankV3 \\");
        console.log("     --watch");
        console.log("===========================================");
    }
}

/**
 * @title DeployKipuBankV3Custom
 * @notice Deployment script with custom parameters
 * @dev Allows customizing all deployment parameters via function arguments
 */
contract DeployKipuBankV3Custom is Script {
    /**
     * @notice Deploys KipuBankV3 with custom parameters
     * @param admin Initial admin address with all roles
     * @param usdc USDC token address
     * @param ethUsdFeed Chainlink ETH/USD price feed address
     * @param uniswapRouter Uniswap V2 Router02 address
     * @param bankCapUSD6 Global bank capacity in USD-6
     * @param withdrawalThresholdUSD6 Per-transaction withdrawal limit in USD-6
     * @param defaultSlippageBps Default slippage tolerance in basis points
     * @return bank Deployed KipuBankV3 contract instance
     * 
     * Usage:
     * forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3Custom \
     *   --sig "run(address,address,address,address,uint256,uint256,uint256)" \
     *   ADMIN_ADDRESS USDC_ADDRESS FEED_ADDRESS ROUTER_ADDRESS 1000000000000 10000000000 100 \
     *   --rpc-url $SEPOLIA_RPC_URL \
     *   --broadcast \
     *   --verify
     */
    function run(
        address admin,
        address usdc,
        address ethUsdFeed,
        address uniswapRouter,
        uint256 bankCapUSD6,
        uint256 withdrawalThresholdUSD6,
        uint256 defaultSlippageBps
    ) external returns (KipuBankV3) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("===========================================");
        console.log("CUSTOM DEPLOYMENT");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("Admin:", admin);
        console.log("USDC:", usdc);
        console.log("ETH/USD Feed:", ethUsdFeed);
        console.log("Uniswap Router:", uniswapRouter);
        console.log("Bank Cap:", bankCapUSD6);
        console.log("Withdrawal Threshold:", withdrawalThresholdUSD6);
        console.log("Slippage:", defaultSlippageBps);
        console.log("===========================================");
        
        vm.startBroadcast(deployerPrivateKey);
        
        KipuBankV3 bank = new KipuBankV3(
            admin,
            usdc,
            ethUsdFeed,
            uniswapRouter,
            bankCapUSD6,
            withdrawalThresholdUSD6,
            defaultSlippageBps
        );
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("KipuBankV3 deployed at:", address(bank));
        console.log("Etherscan URL: https://sepolia.etherscan.io/address/", address(bank));
        
        return bank;
    }
}

/**
 * @title DeployKipuBankV3Mainnet
 * @notice Deployment script for Mainnet (use with extreme caution)
 * @dev Only use after thorough testing on testnet and security audits
 * @dev Requires different addresses for Mainnet contracts
 */
contract DeployKipuBankV3Mainnet is Script {
    // WARNING: These are Mainnet addresses - double-check before deployment
    address constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant ETH_USD_FEED_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant UNISWAP_ROUTER_MAINNET = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    
    // Mainnet configuration (more conservative)
    uint256 constant MAINNET_BANK_CAP = 10_000_000 * 1e6; // 10M USD
    uint256 constant MAINNET_WITHDRAWAL_THRESHOLD = 100_000 * 1e6; // 100k USD
    uint256 constant MAINNET_SLIPPAGE = 50; // 0.5% (tighter)

    function run() external returns (KipuBankV3) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("===========================================");
        console.log("WARNING: MAINNET DEPLOYMENT");
        console.log("===========================================");
        console.log("Network: Ethereum Mainnet");
        console.log("Chain ID: 1");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance / 1e18, "ETH");
        console.log("");
        console.log("IMPORTANT CHECKS:");
        console.log("- Have you completed security audits?");
        console.log("- Have you tested thoroughly on testnet?");
        console.log("- Are all parameters correct?");
        console.log("- Do you have enough ETH for gas?");
        console.log("===========================================");
        
        // Uncomment to enable mainnet deployment
        revert("Mainnet deployment disabled for safety. Review and uncomment to enable.");
        
        // vm.startBroadcast(deployerPrivateKey);
        
        // KipuBankV3 bank = new KipuBankV3(
        //     deployer,
        //     USDC_MAINNET,
        //     ETH_USD_FEED_MAINNET,
        //     UNISWAP_ROUTER_MAINNET,
        //     MAINNET_BANK_CAP,
        //     MAINNET_WITHDRAWAL_THRESHOLD,
        //     MAINNET_SLIPPAGE
        // );
        
        // vm.stopBroadcast();
        
        // console.log("Mainnet deployment at:", address(bank));
        
        // return bank;
    }
}