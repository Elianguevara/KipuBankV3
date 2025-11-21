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

    constructor(address _weth, address _usdc) {
        _WETH = _weth;
        USDC = _usdc;
        expectedOutputAmount = 100 * 10 ** 6;
    }

    function setExpectedOutputAmount(uint256 amount) public {
        expectedOutputAmount = amount;
    }

    function setShouldSwapFail(bool _shouldFail) public {
        shouldSwapFail = _shouldFail;
    }
    
    function setShouldETHTransferFail(bool _shouldFail) public {
        shouldETHTransferFail = _shouldFail;
    }
    
    function WETH() external view override returns (address) {
        return _WETH;
    }

    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view override returns (uint[] memory amounts) 
    {
        if (shouldGetAmountsOutFail) {
            revert("MockRouter: Get amounts out failed");
        }
        
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        amounts[amounts.length - 1] = expectedOutputAmount;
    }

    function swapExactETHForTokens(
        uint /* amountOutMin */, 
        address[] calldata path, 
        address to, 
        uint
    ) external payable override returns (uint[] memory amounts) {
        if (shouldSwapFail) revert("MockRouter: Swap failed");
        
        IERC20(path[path.length - 1]).safeTransfer(to, expectedOutputAmount);
        
        amounts = new uint[](2);
        amounts[0] = msg.value;
        amounts[1] = expectedOutputAmount;
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint /* deadline */
    ) external override returns (uint[] memory amounts) {
        if (shouldSwapFail) revert("MockRouter: Swap failed");

        if (expectedOutputAmount < amountOutMin) {
            revert("MockRouter: KipuBankV3 minOut slippage check failed"); 
        }

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).safeTransfer(to, expectedOutputAmount);

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = expectedOutputAmount;
    }

    function swapExactTokensForETH(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint /* deadline */
    ) external override returns (uint[] memory amounts) {
        if (shouldSwapFail) revert("MockRouter: Swap failed");
        if (shouldETHTransferFail) revert("MockRouter: ETH transfer failed");
        
        if (amountOutMin > 0 && expectedOutputAmount < amountOutMin) {
            revert("MockRouter: Insufficient output amount");
        }

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        
        (bool success, ) = payable(to).call{value: expectedOutputAmount}("");
        require(success, "MockRouter: ETH transfer failed");

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = expectedOutputAmount;
    }

    // ⭐ CRÍTICO: Permite que el contrato reciba ETH
    receive() external payable {}
}