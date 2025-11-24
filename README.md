# 🏦 KipuBankV3

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://docs.soliditylang.org/)
[![Tests](https://img.shields.io/badge/Tests-30%2F30-brightgreen)](./test/)
[![Coverage](https://img.shields.io/badge/Coverage-78%25-green)](./test/)

> **Protocolo Bancario DeFi con Integración de Uniswap V2 para Swaps Automáticos**

**Contrato Verificado en Sepolia**: [`0xF7925F475D7EbF22Fc531C5E2830229C70567172`](https://sepolia.etherscan.io/address/0xF7925F475D7EbF22Fc531C5E2830229C70567172#code)

---

## 📋 Tabla de Contenidos

1. [Descripción General](#descripción-general)
2. [Mejoras Implementadas](#mejoras-implementadas)
3. [Arquitectura y Diseño](#arquitectura-y-diseño)
4. [Despliegue e Interacción](#despliegue-e-interacción)
5. [Análisis de Amenazas y Seguridad](#análisis-de-amenazas-y-seguridad)
6. [Pruebas y Cobertura](#pruebas-y-cobertura)
7. [Roadmap a Producción](#roadmap-a-producción)

---

## 🎯 Descripción General

**KipuBankV3** es la evolución final del proyecto KipuBank, transformándolo en una aplicación DeFi robusta y lista para producción. Este contrato permite a los usuarios depositar no solo ETH y USDC, sino **cualquier token ERC20** con liquidez en Uniswap V2.

El protocolo se encarga automáticamente de:
1. Recibir el token del usuario.
2. Realizar el swap a USDC a través de Uniswap V2.
3. Acreditar el saldo en USDC (USD-6) en la cuenta del usuario.
4. Asegurar que el límite total del banco (`bankCap`) se respete en todo momento.

---

## ✨ Mejoras Implementadas

### 1. 🔄 Integración con Uniswap V2
**Problema en V2**: Los usuarios solo podían depositar tokens específicos (ETH/USDC). Si tenían DAI o LINK, debían ir a un DEX, cambiarlo y luego volver al banco.
**Solución en V3**: Se integra `IUniswapV2Router02`. Ahora el contrato acepta cualquier token, aprueba al router y ejecuta `swapExactTokensForTokens` en una sola transacción atómica.

### 2. 🛡️ Protección de Bank Cap Dinámico
**Requisito**: El banco no debe superar un límite de fondos (riesgo sistémico).
**Implementación**: La verificación `if (currentTotal + amountUSD6 > maxCap)` se realiza **después** del swap, asegurando que el monto real recibido en USDC no viole el límite.

### 3. 🔐 Seguridad Reforzada
- **ReentrancyGuard**: En todas las funciones externas de depósito y retiro.
- **Pausable**: Mecanismo de emergencia para detener operaciones en caso de ataque.
- **AccessControl**: Roles granulares (`DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE`, `TREASURER_ROLE`) en lugar de un simple `Ownable`.
- **SafeERC20**: Uso de la librería de OpenZeppelin para manejar tokens que no retornan bool (como USDT).

### 4. 📉 Manejo de Slippage
El contrato protege al usuario contra el deslizamiento de precios (slippage) permitiendo definir un `minAmountOut` o usando un valor por defecto configurado por el administrador.

---

## 🏗️ Arquitectura y Diseño

### Decisiones de Diseño (Trade-offs)

1.  **Contabilidad Unificada en USDC (USD-6)**:
    *   *Decisión*: Todos los saldos se almacenan normalizados a 6 decimales.
    *   *Ventaja*: Simplifica la lógica interna y el cálculo de riesgo. El usuario siempre sabe cuánto "dólar" tiene.
    *   *Trade-off*: El usuario pierde la exposición al precio del token original (ej. si deposita WBTC, se pasa a USDC y no gana si BTC sube).

2.  **Swap en el Depósito**:
    *   *Decisión*: El swap ocurre síncronamente al depositar.
    *   *Ventaja*: UX superior (1 click).
    *   *Trade-off*: Costo de gas más alto para el usuario en esa transacción.

3.  **Uso de Uniswap V2 (no V3)**:
    *   *Decisión*: Se optó por V2 por su simplicidad y amplia disponibilidad en testnets.
    *   *Ventaja*: Menor complejidad de integración y gas más predecible.

---

## 🚀 Despliegue e Interacción

### Información del Contrato
- **Red**: Sepolia Testnet
- **Dirección**: `0xF7925F475D7EbF22Fc531C5E2830229C70567172`
- **Etherscan**: [Verificado ✅](https://sepolia.etherscan.io/address/0xF7925F475D7EbF22Fc531C5E2830229C70567172#code)

### Cómo Interactuar

**Opción A: Etherscan (Web)**
1. Ve a la pestaña "Write Contract".
2. Conecta tu Wallet.
3. Usa `depositETH` para enviar SepoliaETH.
4. Usa `withdrawUSDC` para retirar tus fondos.

**Opción B: Foundry (CLI)**
```bash
# Depositar ETH
cast send 0xF7925F475D7EbF22Fc531C5E2830229C70567172 "depositETH()" --value 0.01ether --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

# Consultar Saldo
cast call 0xF7925F475D7EbF22Fc531C5E2830229C70567172 "getBalanceUSD6(address)(uint256)" TU_DIRECCION --rpc-url $SEPOLIA_RPC_URL
```

---

## 🕵️ Análisis de Amenazas y Seguridad

### Debilidades Identificadas
1.  **Dependencia de Oráculo Único**: Dependemos de Chainlink para el precio ETH/USD. Si el oráculo falla o se congela, las funciones de consulta de precio podrían revertir (aunque los depósitos directos de tokens seguirían funcionando vía Uniswap).
2.  **Riesgo de Flash Loan**: Aunque tenemos `ReentrancyGuard`, la manipulación de precios en el mismo bloque podría afectar si usáramos oráculos on-chain de Uniswap (actualmente mitigado usando Chainlink para referencias).
3.  **Centralización de Roles**: El `DEFAULT_ADMIN_ROLE` tiene poder total para cambiar el `bankCap` y pausar. En producción, esto debería ser un **TimelockController** o una **MultiSig**.

### Pasos Faltantes para Madurez (Production Ready)
1.  **Implementar TWAP**: Para tener una segunda fuente de verdad en precios y evitar manipulación de oráculos en una sola transacción.
2.  **Whitelist de Tokens**: Limitar qué tokens se pueden depositar para evitar tokens maliciosos con lógica de transferencia extraña o tarifas de quema (fee-on-transfer) que rompan la contabilidad.
3.  **Auditoría Externa**: Revisión por una firma de seguridad independiente.

---

## 🧪 Pruebas y Cobertura

El proyecto utiliza **Foundry** para un suite de pruebas exhaustivo.

### Métodos de Prueba
1.  **Unit Tests**: Pruebas aisladas de cada función (`deposit`, `withdraw`, `access control`).
2.  **Integration Tests**: Pruebas con Mocks de Uniswap y Chainlink para simular interacciones externas.
3.  **Fuzzing**: Pruebas con miles de inputs aleatorios para asegurar que el `bankCap` nunca se rompe y no hay desbordamientos (overflows).
4.  **Fork Testing**: Pruebas en un fork de Sepolia real para verificar la integración con contratos existentes.

### Resultado de Cobertura
Se ha superado el requisito del 50%.

| Archivo | % Líneas | % Funciones | Estado |
|---------|----------|-------------|--------|
| `KipuBankV3.sol` | **95.07%** | **100.00%** | ✅ Aprobado |

Para ejecutar las pruebas:
```bash
forge test
forge coverage
```

---

## 🛣️ Roadmap a Producción

- [x] Desarrollo de Smart Contracts (V3)
- [x] Pruebas Unitarias y Fuzzing
- [x] Despliegue en Testnet (Sepolia)
- [x] Verificación en Etherscan
- [ ] Auditoría de Seguridad
- [ ] Implementación de MultiSig para Admin
- [ ] Lanzamiento en Mainnet

---

_Trabajo Final Módulo 4 - 2025_
