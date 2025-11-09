// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockRouterV2 {
    
    mapping(address => uint256) public ratioToUSDC; 

    address public immutable USDC;

    constructor(address _usdc) {
        USDC = _usdc;
    }

    function setRatio(address tokenIn, uint256 usdcPerToken) external {
        // usdcPerToken expresado en 6 decimales (ej: 2e6 = 2 USDC)
        ratioToUSDC[tokenIn] = usdcPerToken;
    }

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        require(path.length == 2, "only direct path");
        require(path[1] == USDC, "dst must be USDC");
        uint256 out = (amountIn * ratioToUSDC[path[0]]) / 1e18; // si querés 1:1 con 18 dec, seteá ratio=1e18?
        // Más simple: interpretamos amountIn en 18 dec y ratio en 6 dec — para test basta ser consistente
        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external returns (uint[] memory amounts) {
        require(path.length == 2, "only direct path");
        require(path[1] == USDC, "dst must be USDC");

        // Cobrar tokenIn
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        uint256 out = (amountIn * ratioToUSDC[path[0]]) / 1e18;
        require(out >= amountOutMin, "slippage");

        // Enviar USDC desde el router al 'to'
        IERC20(USDC).transfer(to, out);

        amounts = new uint[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}
