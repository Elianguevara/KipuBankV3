// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockUniswapRouter
 * @notice Mock implementation of the IUniswapV2Router02 interface for controlled testing of swap logic.
 * @dev Allows tests to set expected output amounts and simulate swap failures.
 */
contract MockUniswapRouter is IUniswapV2Router02 {
    using SafeERC20 for IERC20;

    /// @notice Address of the WETH token.
    address public immutable _WETH;
    /// @notice Address of the USDC token.
    address public immutable USDC;
    
    /// @notice Configurable mock return value for output tokens.
    uint256 public expectedOutputAmount;
    /// @notice Flag to simulate a swap failure (reverts the swap function).
    bool public shouldSwapFail;
    /// @notice Flag to simulate a `getAmountsOut` failure.
    bool public shouldGetAmountsOutFail;
    /// @notice Flag to simulate an ETH transfer failure during `swapExactTokensForETH`.
    bool public shouldETHTransferFail;

    /**
     * @notice Initializes the mock router with the WETH and USDC addresses.
     * @param _weth WETH token address.
     * @param _usdc USDC token address.
     */
    constructor(address _weth, address _usdc) {
        _WETH = _weth;
        USDC = _usdc;
        // Default expected output set low for simple verification
        expectedOutputAmount = 100 * 10 ** 6; // $100 USDC (6 decimals)
    }

    // --- Configuration Functions (Set by tests) ---

    /// @notice Sets the mocked expected output amount for swaps.
    function setExpectedOutputAmount(uint256 amount) public {
        expectedOutputAmount = amount;
    }

    /// @notice Sets the flag to simulate swap failures.
    function setShouldSwapFail(bool _shouldFail) public {
        shouldSwapFail = _shouldFail;
    }
    
    /// @notice Sets the flag to simulate ETH transfer failures in a swap.
    function setShouldETHTransferFail(bool _shouldFail) public {
        shouldETHTransferFail = _shouldFail;
    }
    
    // --- IUniswapV2Router02 Implementation ---

    /// @notice Returns the mocked WETH address.
    function WETH() external view override returns (address) {
        return _WETH;
    }

    /// @notice Mocks the calculation of output amounts.
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view override returns (uint[] memory amounts) 
    {
        if (shouldGetAmountsOutFail) {
            revert("MockRouter: Get amounts out failed");
        }
        
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        
        // For testing purposes, the expected output is always the pre-configured value.
        // This simulates a price calculation based on reserves.
        amounts[amounts.length - 1] = expectedOutputAmount;
    }

    /// @notice Mocks swapping ETH for tokens (USDC).
    function swapExactETHForTokens(
        uint /* amountOutMin */, 
        address[] calldata path, 
        address to, 
        uint
    ) external payable override returns (uint[] memory amounts) {
        if (shouldSwapFail) revert("MockRouter: Swap failed");
        
        // Transfer output token (USDC) to the contract (bank)
        IERC20(path[path.length - 1]).safeTransfer(to, expectedOutputAmount);
        
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = expectedOutputAmount;
    }

    /// @notice Mocks swapping Token for Token (ERC20 to USDC).
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin ,
        address[] calldata path,
        address to,
        uint /* deadline */
    ) external override returns (uint[] memory amounts) {
        if (shouldSwapFail) revert("MockRouter: Swap failed");

        
        if (expectedOutputAmount < amountOutMin) {
            revert("MockRouter: KipuBankV3 minOut slippage check failed"); 
        }

        // Take input token from the caller (bank)
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Transfer output token (USDC) to the receiver (bank)
        IERC20(path[path.length - 1]).safeTransfer(to, expectedOutputAmount);

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = expectedOutputAmount;
    }

    /// @notice Mocks swapping Token (USDC) for ETH.
    function swapExactTokensForETH(
        uint amountIn, 
        uint /* amountOutMin */, 
        address[] calldata path, 
        address to, 
        uint /* deadline */
    ) external override returns (uint[] memory amounts) {
        if (shouldSwapFail) revert("MockRouter: Swap failed");

        // Take input token (USDC) from the caller (bank)
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Send native ETH to the recipient ('to')
        if (shouldETHTransferFail) {
             revert("MockRouter: ETH transfer failed");
        }
        
        (bool success, ) = payable(to).call{value: expectedOutputAmount}("");
        if (!success) revert("MockRouter: ETH transfer failed unexpectedly");

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = expectedOutputAmount;
    }
}