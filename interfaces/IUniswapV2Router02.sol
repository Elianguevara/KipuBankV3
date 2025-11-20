// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IUniswapV2Router02
 * @notice Minimal interface for the Uniswap V2 Router, required to perform swaps.
 */
interface IUniswapV2Router02 {
    /**
     * @notice Swaps an exact amount of input tokens for a minimum amount of output tokens.
     * @param amountIn The exact amount of input token to spend.
     * @param amountOutMin The minimum amount of output token to receive.
     * @param path An array of token addresses defining the swap route (e.g., [tokenA, tokenB]).
     * @param to Address that will receive the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     * @return amounts The array of token amounts along the path.
     */
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    /**
     * @notice Swaps an exact amount of native ETH for a minimum amount of ERC20 tokens.
     * @param amountOutMin The minimum amount of output token to receive.
     * @param path An array of token addresses defining the swap route (e.g., [WETH, tokenB]).
     * @param to Address that will receive the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     * @return amounts The array of token amounts along the path.
     */
    function swapExactETHForTokens(
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external payable returns (uint[] memory amounts);

    /**
     * @notice Swaps an exact amount of input ERC20 tokens for a minimum amount of native ETH.
     * @param amountIn The exact amount of input token to spend.
     * @param amountOutMin The minimum amount of ETH to receive.
     * @param path An array of token addresses defining the swap route (e.g., [tokenA, WETH]).
     * @param to Address that will receive the ETH (sent directly by the router).
     * @param deadline Unix timestamp after which the transaction will revert.
     * @return amounts The array of token amounts along the path.
     */
    function swapExactTokensForETH(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external returns (uint[] memory amounts);

    /**
     * @notice Retrieves the expected output amounts for a given input amount and path.
     * @param amountIn Input token amount.
     * @param path Swap path.
     * @return amounts The token amounts along the route.
     */
    function getAmountsOut(uint amountIn, address[] calldata path) 
        external view returns (uint[] memory amounts);
        
    /**
     * @notice Returns the address of the Wrapped Ether (WETH) token.
     * @return WETH The address of the WETH contract.
     */
    function WETH() external view returns (address);
}