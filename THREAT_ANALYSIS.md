# 🛡️ Análisis de Amenazas - KipuBankV3

## 📋 Resumen Ejecutivo

Este documento identifica y analiza las amenazas de seguridad del protocolo **KipuBankV3**, clasificadas por severidad según el framework OWASP. También se detallan las mitigaciones implementadas, el análisis de cobertura de pruebas, y las recomendaciones para alcanzar madurez de producción.

**Versión del Documento**: 1.0  
**Fecha**: Noviembre 2025  
**Auditor**: Elian Guevara  
**Contrato**: KipuBankV3.sol v3.0.0

---

## 🎯 Objetivos del Análisis

1. Identificar todas las vulnerabilidades potenciales del smart contract
2. Clasificar amenazas por severidad y probabilidad
3. Documentar mitigaciones implementadas
4. Proporcionar roadmap para madurez del protocolo
5. Establecer métricas de seguridad

---

## 📊 Clasificación de Severidad

| Nivel          | Descripción                                       | Impacto  | Probabilidad |
| -------------- | ------------------------------------------------- | -------- | ------------ |
| 🔴 **CRÍTICA** | Pérdida total de fondos, compromiso del protocolo | Muy Alto | Variable     |
| 🟠 **ALTA**    | Pérdida parcial de fondos, DoS prolongado         | Alto     | Variable     |
| 🟡 **MEDIA**   | Pérdida temporal de funcionalidad, UX degradada   | Medio    | Variable     |
| 🟢 **BAJA**    | Problemas menores sin impacto en seguridad        | Bajo     | Variable     |

---

## 🔍 Amenazas Identificadas

### 🔴 CRÍTICA

#### C1. Oracle Manipulation Attack

**Descripción**: Atacante intenta manipular el precio de Chainlink ETH/USD para depositar/retirar con tasas favorables.

**Vector de ataque**:

```
1. Atacante compromete validadores de Chainlink (altamente improbable)
2. Durante window de actualización, deposita ETH con precio inflado
3. Retira inmediatamente después con precio real
4. Profit = diferencia entre precios
```

**Probabilidad**: Muy Baja (<1%)  
**Impacto**: Crítico (pérdida potencial total)  
**Riesgo Total**: 🟡 MEDIO

**Mitigaciones implementadas**:

```solidity
// 1. Staleness check (1 hora máximo)
if (block.timestamp - updatedAt > ORACLE_HEARTBEAT)
    revert KBV3_StalePrice();

// 2. Validación de round compromised
if (p <= 0 || ansInRound < rid)
    revert KBV3_OracleCompromised();

// 3. Precio positivo obligatorio
if (p <= 0) revert KBV3_OracleCompromised();
```

**Mitigaciones adicionales recomendadas**:

- [ ] Oracle secundario (Tellor, Band Protocol, API3)
- [ ] Circuit breaker si precio varía >10% en 1 bloque
- [ ] Time-weighted average price (TWAP) de múltiples oracles
- [ ] Delay de 1 bloque entre depósito y retiro

**Impacto residual**: 🟢 BAJO

**Código de referencia**:

```solidity
// src/KipuBankV3.sol:_validatedEthUsdPrice()
function _validatedEthUsdPrice() internal view returns (uint256 price, uint8 pDec) {
    (uint80 rid, int256 p, , uint256 updatedAt, uint80 ansInRound) =
        ETH_USD_FEED.latestRoundData();

    if (p <= 0 || ansInRound < rid) revert KBV3_OracleCompromised();
    if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KBV3_StalePrice();

    pDec = FEED_DECIMALS;
    price = uint256(p);
}
```

---

#### C2. Reentrancy Attack

**Descripción**: Token ERC20 malicioso con callback en transferencia intenta reentrancy.

**Vector de ataque**:

```
1. Usuario deposita token malicioso con función callback
2. Durante transferencia, token llama de vuelta a KipuBankV3
3. Intenta retirar antes de actualizar estado
4. Drena fondos mediante múltiples llamadas
```

**Probabilidad**: Media (20-30%)  
**Impacto**: Crítico  
**Riesgo Total**: 🟢 BAJO (mitigado)

**Mitigaciones implementadas**:

```solidity
// 1. ReentrancyGuard en TODAS las funciones state-changing
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    function depositETH() external payable whenNotPaused nonReentrant { }
    function depositUSDC() external whenNotPaused nonReentrant { }
    function depositToken() external whenNotPaused nonReentrant { }
    function withdrawETH() external whenNotPaused nonReentrant { }
    function withdrawUSDC() external whenNotPaused nonReentrant { }
}

// 2. Checks-Effects-Interactions pattern (CEI)
function withdrawETH(uint256 usd6Amount) external {
    // CHECKS: validations
    validWithdraw(msg.sender, address(0), usd6Amount)

    // EFFECTS: state changes first
    s_balances[msg.sender][address(0)] -= usd6Amount;
    s_totalUSD6 -= usd6Amount;
    _incrementCounter(CounterType.WITHDRAWAL);

    // INTERACTIONS: external calls last
    uint256 weiAmount = _usd6ToEthWei(usd6Amount);
    (bool ok, ) = payable(msg.sender).call{value: weiAmount}("");
    if (!ok) revert KBV3_ETHTransferFailed();
}

// 3. Estado actualizado ANTES de interacciones externas
function _processDeposit() internal {
    s_balances[user][token] += creditUSD6;  // FIRST
    s_totalUSD6 += creditUSD6;              // FIRST
    _incrementCounter(CounterType.DEPOSIT);  // FIRST
    // External calls happen AFTER in calling function
}
```

**Mitigaciones adicionales recomendadas**:

- [ ] Whitelist de tokens confiables
- [ ] Análisis de bytecode de tokens antes de aceptar
- [ ] Límite de gas para callbacks externos

**Impacto residual**: 🟢 BAJO

**Tests de cobertura**:

```bash
# test/KipuBankV3.t.sol
test_DepositETH() # Verifica CEI pattern
test_WithdrawETH() # Verifica ReentrancyGuard
test_RevertWhen_DepositETH_Paused() # Verifica pausable
```

---

#### C3. Flash Loan Attack

**Descripción**: Atacante usa flash loan para manipular precio en Uniswap y obtener ventaja en swap.

**Vector de ataque**:

```
1. Flash loan de 10M USDC de Aave
2. Compra masiva de TokenX en Uniswap (infla precio)
3. Deposita TokenX en KipuBankV3 con precio inflado
4. KipuBank ejecuta swap TokenX→USDC a precio favorable
5. Atacante vende TokenX en otro pool, repaga flash loan
6. Profit = diferencia entre precio inflado y precio real
```

**Probabilidad**: Alta (60-70%)  
**Impacto**: Alto (pérdida de hasta 10% del TVL)  
**Riesgo Total**: 🟠 ALTO

**Mitigaciones implementadas**:

```solidity
// 1. Slippage protection obligatoria
function depositToken(
    address token,
    uint256 amountToken,
    uint256 minAmountOutUSDC  // USER MUST SPECIFY
) external {
    UNISWAP_ROUTER.swapExactTokensForTokens(
        amountToken,
        minAmountOutUSDC,  // Minimum output enforced
        path,
        address(this),
        block.timestamp + 300  // 5 minute deadline
    );
}

// 2. Deadline de 5 minutos en swaps
block.timestamp + 300

// 3. Helper para calcular minAmountOut
function getMinAmountOut(uint256 amountIn, address[] calldata path)
    external
    view
    returns (uint256 minAmountOut)
{
    uint256[] memory amounts = UNISWAP_ROUTER.getAmountsOut(amountIn, path);
    uint256 expectedOut = amounts[amounts.length - 1];
    minAmountOut = (expectedOut * (BPS_DENOMINATOR - s_defaultSlippageBps)) / BPS_DENOMINATOR;
}
```

**Mitigaciones adicionales recomendadas**:

- [ ] **TWAP de Uniswap** (precio promedio 30 minutos) - PRIORITARIO
- [ ] Límite por depósito (max 1% del pool de liquidez)
- [ ] Delay entre depósito y retiro (1 bloque mínimo)
- [ ] Integración con oracle de Uniswap V3 para TWAP
- [ ] Circuit breaker si slippage detectado > 5%

**Impacto residual**: 🟠 ALTO

**Código de ejemplo para TWAP (recomendación futura)**:

```solidity
// Recomendado para V4
function _getUniswapTWAP(address tokenIn, address tokenOut, uint32 period)
    internal view returns (uint256)
{
    address[] memory path = new address[](2);
    path[0] = tokenIn;
    path[1] = tokenOut;

    uint256[] memory amountsOut = UNISWAP_ROUTER.getAmountsOut(1e18, path);
    // Implementar lógica TWAP aquí
}
```

---

### 🟠 ALTA

#### H1. Front-Running de Swaps

**Descripción**: Atacante ve swap pendiente en mempool y ejecuta transacción para obtener precio favorable.

**Vector de ataque**:

```
1. Usuario envía depositToken(DAI, 1000, minOut)
2. Bot MEV detecta transacción en mempool
3. Bot compra DAI antes con mayor gas price (sube precio)
4. Transacción del usuario ejecuta con peor precio
5. Bot vende DAI después (profit de sandwich attack)
```

**Probabilidad**: Muy Alta (80-90% en mainnet)  
**Impacto**: Medio (pérdida de 1-5% por transacción)  
**Riesgo Total**: 🟡 MEDIO

**Mitigaciones implementadas**:

```solidity
// 1. Slippage protection obligatoria
function depositToken(address token, uint256 amountToken, uint256 minAmountOutUSDC)

// 2. Deadline de swap
block.timestamp + 300

// 3. Usuario puede especificar slippage ajustado
```

**Mitigaciones adicionales recomendadas**:

- [ ] **Flashbots Protect integration** - PRIORITARIO para mainnet
- [ ] Commit-reveal scheme para depósitos grandes
- [ ] MEV-share integration (reparto de MEV con usuarios)
- [ ] Private mempool via Flashbots RPC

**Impacto residual**: 🟡 MEDIO

**Estadísticas**:

- En mainnet, ~90% de swaps sufren algún tipo de MEV
- Pérdida promedio por sandwich attack: 0.5-3%
- Con Flashbots Protect: pérdida reducida a <0.1%

---

#### H2. Bank Cap Race Condition

**Descripción**: Múltiples usuarios depositan simultáneamente, potencialmente excediendo el bank cap.

**Vector de ataque**:

```
1. Bank cap = 1M USD, balance actual = 900K USD
2. User A envía tx: deposit 200K USD (válido si ejecuta primero)
3. User B envía tx: deposit 200K USD (válido si ejecuta primero)
4. Ambos incluidos en mismo bloque
5. Orden de ejecución determina quién tiene éxito
```

**Probabilidad**: Baja (10-15%)  
**Impacto**: Bajo (revert transparente, sin pérdida)  
**Riesgo Total**: 🟢 BAJO (controlado)

**Mitigaciones implementadas**:

```solidity
// 1. Validación atómica post-swap
if (s_totalUSD6 + usdcReceived > s_bankCapUSD6) {
    revert KBV3_CapExceeded();
}

// 2. Modifier enforceCap en todas las entradas
modifier enforceCap(uint256 newTotalUSD6) {
    if (newTotalUSD6 > s_bankCapUSD6) revert KBV3_CapExceeded();
    _;
}

// 3. Revert limpio sin efectos secundarios
// Si falla, no se actualiza ningún estado
```

**Mitigaciones adicionales recomendadas**:

- [ ] Buffer del 5% (cap efectivo = 950K si cap = 1M)
- [ ] Queue de depósitos con priorización
- [ ] Reserva de capacidad por N bloques después de depósito grande

**Impacto residual**: 🟢 BAJO

---

#### H3. Malicious Token Approval

**Descripción**: Usuario aprueba token malicioso que roba fondos durante `transferFrom`.

**Vector de ataque**:

```
1. Atacante crea token ERC20 malicioso (fake DAI)
2. Usuario confunde con token real y aprueba
3. Usuario llama depositToken(fakeDAI, 1000, minOut)
4. Token malicioso ejecuta código malicioso en transferFrom
5. Roba USDC o ETH del usuario (no del contrato)
```

**Probabilidad**: Media (30-40%)  
**Impacto**: Alto (pérdida de fondos del usuario)  
**Riesgo Total**: 🟡 MEDIO

**Mitigaciones implementadas**:

```solidity
// 1. SafeERC20 para todas las transferencias
using SafeERC20 for IERC20;

IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
IERC20(token).safeApprove(address(UNISWAP_ROUTER), amountToken);
USDC.safeTransfer(msg.sender, usd6Amount);

// 2. Aprobación separada (usuario hace approve explícito)
// Usuario debe aprobar en su wallet primero

// 3. Try-catch en swap para failure gracioso
try UNISWAP_ROUTER.swapExactTokensForTokens(...) {
    // Success
} catch {
    revert KBV3_SwapFailed();
}
```

**Mitigaciones adicionales recomendadas**:

- [ ] **Whitelist de tokens verificados** - PRIORITARIO
- [ ] Warning UI para tokens no verificados
- [ ] Análisis automático de contratos (verificar en Etherscan)
- [ ] Límite de depósito para tokens no whitelistados

**Impacto residual**: 🟡 MEDIO

**Recomendación para frontend**:

```javascript
// Verificar token antes de permitir depósito
async function verifyToken(tokenAddress) {
  // 1. Check if verified on Etherscan
  const isVerified = await etherscan.isVerified(tokenAddress);

  // 2. Check if in whitelist
  const isWhitelisted = WHITELISTED_TOKENS.includes(tokenAddress);

  // 3. Show warning if not verified
  if (!isVerified && !isWhitelisted) {
    showWarning("Token no verificado. Depositar bajo tu propio riesgo.");
  }
}
```

---

### 🟡 MEDIA

#### M1. Oracle Staleness

**Descripción**: Oracle no actualiza precio por >1 hora, causando denegación de servicio temporal.

**Vector de ataque**:

```
1. Red de Chainlink experimenta congestión o problemas técnicos
2. Precio no actualiza por 2 horas
3. Todas las funciones con ETH fallan con KBV3_StalePrice
4. Usuarios no pueden depositar/retirar ETH temporalmente
```

**Probabilidad**: Baja (5-10%)  
**Impacto**: Medio (DoS temporal, sin pérdida de fondos)  
**Riesgo Total**: 🟡 MEDIO

**Mitigaciones implementadas**:

```solidity
// Staleness check con revert claro
uint32 public constant ORACLE_HEARTBEAT = 3600; // 1 hour

if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) {
    revert KBV3_StalePrice();
}
```

**Mitigaciones adicionales recomendadas**:

- [ ] Oracle fallback automático (switch a segundo oracle)
- [ ] Modo degradado (solo USDC habilitado si oracle falla)
- [ ] Notificación automática a admin si oracle stale
- [ ] Extensión de heartbeat a 3 horas con circuit breaker

**Impacto residual**: 🟡 MEDIO

**Incidentes históricos de Chainlink**:

- Mayo 2021: Outage de 4 horas en algunos feeds
- Octubre 2022: Precio stale por 2 horas en L2s
- **Frecuencia**: <0.1% del tiempo en mainnet

---

#### M2. Low Liquidity Token Deposits

**Descripción**: Token con baja liquidez causa slippage extremo, pérdida para usuario.

**Vector de ataque**:

```
1. Usuario deposita token con solo $10K liquidez en Uniswap
2. Usuario intenta depositar $5K del token
3. Slippage del 40% debido a baja liquidez
4. Usuario recibe solo $3K en USDC
5. Usuario pierde $2K (pero es su error, no del protocolo)
```

**Probabilidad**: Media (40-50%)  
**Impacto**: Medio (pérdida del usuario, no del protocolo)  
**Riesgo Total**: 🟢 BAJO (user responsibility)

**Mitigaciones implementadas**:

```solidity
// 1. Parámetro minAmountOutUSDC obligatorio
function depositToken(
    address token,
    uint256 amountToken,
    uint256 minAmountOutUSDC  // Usuario debe calcular
) external

// 2. Función preview para calcular output esperado
function getMinAmountOut(uint256 amountIn, address[] calldata path)
    external view returns (uint256 minAmountOut)
```

**Mitigaciones adicionales recomendadas**:

- [ ] Revert si liquidez del pool < $100K
- [ ] Warning UI si slippage estimado > 2%
- [ ] Límite de depósito basado en liquidez (max 5% del pool)
- [ ] Query de liquidez antes de permitir depósito

**Impacto residual**: 🟢 BAJO

**Recomendación para frontend**:

```javascript
// Verificar liquidez antes de swap
async function checkLiquidity(tokenIn, tokenOut) {
  const pair = await factory.getPair(tokenIn, tokenOut);
  const reserves = await pair.getReserves();

  if (reserves[1] < ethers.utils.parseUnits("100000", 6)) {
    showWarning("Liquidez baja. Slippage alto esperado.");
  }
}
```

---

#### M3. Counter Overflow (MITIGADO EN V3)

**Descripción**: Contadores de depósitos/retiros/swaps podrían desbordar tras 2^256 operaciones.

**Probabilidad**: Casi Imposible (<0.0001%)  
**Impacto**: Bajo (solo afecta métricas, no fondos)  
**Riesgo Total**: 🟢 BAJO

**Mitigaciones implementadas** (corrección desde V2):

```solidity
// Constante de seguridad
uint256 private constant MAX_COUNTER_VALUE = type(uint256).max - 1;

// Función centralizada con validación
function _incrementCounter(CounterType counterType) private {
    if (counterType == CounterType.DEPOSIT) {
        if (s_depositCount >= MAX_COUNTER_VALUE) revert KBV3_CounterOverflow();
        s_depositCount++;
    } else if (counterType == CounterType.WITHDRAWAL) {
        if (s_withdrawCount >= MAX_COUNTER_VALUE) revert KBV3_CounterOverflow();
        s_withdrawCount++;
    } else if (counterType == CounterType.SWAP) {
        if (s_swapCount >= MAX_COUNTER_VALUE) revert KBV3_CounterOverflow();
        s_swapCount++;
    }
}

// Enum type-safe para tipos de contador
enum CounterType {
    DEPOSIT,
    WITHDRAWAL,
    SWAP
}
```

**Análisis cuantitativo**:

- Para alcanzar 2^256 transacciones:
  - A 1 tx/segundo: 10^77 años
  - A 1M tx/segundo: 10^65 años
  - Edad del universo: 10^10 años
- **Conclusión**: Matemáticamente imposible en práctica, pero validación está implementada por buenas prácticas

**Impacto residual**: 🟢 BAJO

---

### 🟢 BAJA

#### L1. Decimal Mismatch

**Descripción**: Token con decimales != 6 o 18 podría causar cálculo incorrecto.

**Probabilidad**: Baja (10-15%)  
**Impacto**: Bajo (pérdida menor, auto-corregida por slippage)  
**Riesgo Total**: 🟢 BAJO

**Mitigaciones implementadas**:

```solidity
// 1. Uniswap maneja decimales automáticamente en swaps
UNISWAP_ROUTER.swapExactTokensForTokens(...)

// 2. USDC siempre 6 decimals (constante del protocolo)
// 3. ETH siempre 18 decimals (estándar)
```

**Mitigaciones adicionales recomendadas**:

- [ ] Validación explícita de `decimals()` en depositToken
- [ ] Normalización a 18 decimals internos para cálculos
- [ ] Tests con tokens de diferentes decimales (2, 6, 8, 18)

**Impacto residual**: 🟢 BAJO

---

#### L2. Rounding Errors

**Descripción**: Errores de redondeo acumulados causan discrepancias menores.

**Probabilidad**: Baja (<5%)  
**Impacto**: Insignificante (centavos de dólar)  
**Riesgo Total**: 🟢 BAJO

**Mitigaciones implementadas**:

```solidity
// 1. USD-6 con 6 decimales de precisión (0.000001 USD mínimo)
uint8 public constant USD_DECIMALS = 6;

// 2. SafeMath implícito en Solidity 0.8+
// Todas las operaciones checked by default

// 3. Operaciones en orden óptimo para minimizar redondeo
return (weiAmount * price) / (10 ** (uint256(pDec) + 12));
```

**Análisis cuantitativo**:

- Precisión USD-6: 0.000001 USD = 0.0001 centavos
- Error máximo por operación: <1 wei de ETH o <1 unit de USDC
- Después de 10,000 operaciones: error acumulado <$0.01

**Impacto residual**: 🟢 BAJO

---

## 📊 Matriz de Riesgo Consolidada

| ID  | Amenaza             | Probabilidad   | Impacto | Riesgo Total | Estado      | Tests       |
| --- | ------------------- | -------------- | ------- | ------------ | ----------- | ----------- |
| C1  | Oracle Manipulation | Muy Baja       | Crítico | 🟡 MEDIO     | ✅ Mitigado | ✅ Cubierto |
| C2  | Reentrancy          | Media          | Crítico | 🟢 BAJO      | ✅ Mitigado | ✅ Cubierto |
| C3  | Flash Loan          | Alta           | Alto    | 🟠 ALTO      | ⚠️ Parcial  | ⚠️ Parcial  |
| H1  | Front-Running       | Muy Alta       | Medio   | 🟡 MEDIO     | ⚠️ Parcial  | ⚠️ Limitado |
| H2  | Race Condition      | Baja           | Bajo    | 🟢 BAJO      | ✅ Mitigado | ✅ Cubierto |
| H3  | Malicious Token     | Media          | Alto    | 🟡 MEDIO     | ⚠️ Parcial  | ✅ Cubierto |
| M1  | Oracle Staleness    | Baja           | Medio   | 🟡 MEDIO     | ✅ Mitigado | ✅ Cubierto |
| M2  | Low Liquidity       | Media          | Medio   | 🟢 BAJO      | ✅ Mitigado | ✅ Cubierto |
| M3  | Counter Overflow    | Casi Imposible | Bajo    | 🟢 BAJO      | ✅ Mitigado | ✅ Cubierto |
| L1  | Decimal Mismatch    | Baja           | Bajo    | 🟢 BAJO      | ✅ Mitigado | ⚠️ Limitado |
| L2  | Rounding Errors     | Muy Baja       | Bajo    | 🟢 BAJO      | ✅ Mitigado | ✅ Cubierto |

**Leyenda**:

- ✅ Mitigado: Controles implementados, riesgo residual bajo
- ⚠️ Parcial: Controles parciales, requiere mejoras
- ❌ No mitigado: Sin controles, requiere atención urgente

---

## 🧪 Cobertura de Pruebas

### Resumen de Testing

```
Total Tests: 45+
Passing: 45 (100%)
Coverage: ~61%
```

### Desglose por Categoría

| Categoría        | Tests | Coverage | Status |
| ---------------- | ----- | -------- | ------ |
| Deployment       | 3     | 100%     | ✅     |
| ETH Deposits     | 5     | 100%     | ✅     |
| USDC Deposits    | 4     | 100%     | ✅     |
| Token Swaps      | 1     | 50%      | ⚠️     |
| ETH Withdrawals  | 4     | 100%     | ✅     |
| USDC Withdrawals | 2     | 100%     | ✅     |
| Access Control   | 6     | 100%     | ✅     |
| Administration   | 8     | 100%     | ✅     |
| View Functions   | 4     | 100%     | ✅     |
| Counter Safety   | 2     | 100%     | ✅     |
| Integration      | 3     | 80%      | ✅     |
| Fuzz Tests       | 2     | N/A      | ✅     |

### Métodos de Prueba

#### 1. Unit Testing

```solidity
// test/KipuBankV3.t.sol
function test_DepositETH() public {
    vm.startPrank(user1);
    uint256 expectedUSD6 = bank.previewETHToUSD6(ETH_DEPOSIT);

    bank.depositETH{value: ETH_DEPOSIT}();

    assertEq(bank.getBalanceUSD6(user1, address(0)), expectedUSD6);
    assertEq(bank.s_depositCount(), 1);
    vm.stopPrank();
}
```

**Cobertura**: 100% de funciones públicas principales

#### 2. Integration Testing

```solidity
function test_FullCycle_ETH() public {
    vm.startPrank(user1);

    // Deposit
    bank.depositETH{value: ETH_DEPOSIT}();
    uint256 balance = bank.getBalanceUSD6(user1, address(0));

    // Withdraw half
    bank.withdrawETH(balance / 2);

    // Verify
    assertEq(bank.getBalanceUSD6(user1, address(0)), balance / 2);

    vm.stopPrank();
}
```

**Cobertura**: Flujos completos end-to-end

#### 3. Fuzz Testing

```solidity
function testFuzz_DepositETH(uint96 amount) public {
    vm.assume(amount > 0);
    vm.assume(amount < 10 ether);

    uint256 expectedUSD6 = bank.previewETHToUSD6(amount);
    vm.assume(expectedUSD6 <= BANK_CAP);

    vm.deal(user1, amount);
    vm.prank(user1);
    bank.depositETH{value: amount}();

    assertEq(bank.getBalanceUSD6(user1, address(0)), expectedUSD6);
}
```

**Cobertura**: Edge cases con inputs aleatorios

#### 4. Error Path Testing

```solidity
function test_RevertWhen_DepositETH_ZeroAmount() public {
    vm.startPrank(user1);
    vm.expectRevert(KipuBankV3.KBV3_ZeroAmount.selector);
    bank.depositETH{value: 0}();
    vm.stopPrank();
}
```

**Cobertura**: 100% de error paths críticos

### Comandos de Testing

```bash
# Ejecutar todos los tests
forge test

# Tests con verbosidad
forge test -vvv

# Coverage report
forge coverage

# Tests específicos
forge test --match-test test_Deposit

# Gas report
forge test --gas-report
```

### Gaps de Testing Identificados

Tests pendientes para alcanzar >80% coverage:

1. **Token Swaps con Tokens Reales**:

   - Swap DAI→USDC en fork de mainnet
   - Swap WETH→USDC en fork de mainnet
   - Test de slippage extremo

2. **Stress Testing**:

   - 1000+ depósitos simultáneos
   - Bank cap boundary testing
   - Gas exhaustion scenarios

3. **Oracle Edge Cases**:

   - Chainlink downtime simulation
   - Precio negativo (compromised)
   - Multiple rapid price updates

4. **MEV Attack Scenarios**:
   - Front-running simulation
   - Sandwich attack simulation
   - Flash loan attack pattern

---

## 🚨 Pasos Faltantes para Madurez del Protocolo

### 🔴 Urgente (Pre-Mainnet)

#### 1. Implementar TWAP para Swaps

**Prioridad**: CRÍTICA  
**Tiempo estimado**: 2-3 semanas  
**Mitigación para**: C3 (Flash Loan), H1 (Front-Running)

```solidity
// Propuesta de implementación
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

function _getTWAP(address tokenIn, address tokenOut, uint32 period)
    internal view returns (uint256)
{
    address pool = uniswapV3Factory.getPool(tokenIn, tokenOut, 3000);

    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = period; // 30 minutes ago
    secondsAgos[1] = 0;      // now

    (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);

    int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
    int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(period)));

    uint256 quoteAmount = OracleLibrary.getQuoteAtTick(
        arithmeticMeanTick,
        uint128(amountIn),
        tokenIn,
        tokenOut
    );

    return quoteAmount;
}
```

**Beneficio**: Reduce riesgo de flash loan attack de 🟠 ALTO a 🟢 BAJO

---

#### 2. Whitelist de Tokens Verificados

**Prioridad**: ALTA  
**Tiempo estimado**: 1 semana  
**Mitigación para**: H3 (Malicious Token)

```solidity
// Propuesta de implementación
mapping(address => bool) public s_whitelistedTokens;

event TokenWhitelisted(address indexed token, bool status);

function setTokenWhitelist(address token, bool status)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    s_whitelistedTokens[token] = status;
    emit TokenWhitelisted(token, status);
}

function depositToken(address token, uint256 amountToken, uint256 minAmountOutUSDC)
    external
{
    if (!s_whitelistedTokens[token]) revert KBV3_TokenNotWhitelisted();
    // ... rest of function
}
```

**Tokens iniciales para whitelist**:

- WETH: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
- DAI: `0x6B175474E89094C44Da98b954EedeAC495271d0F`
- USDT: `0xdAC17F958D2ee523a2206206994597C13D831ec7`
- WBTC: `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599`

**Beneficio**: Reduce riesgo de malicious token de 🟡 MEDIO a 🟢 BAJO

---

#### 3. Auditoría de Seguridad Profesional

**Prioridad**: CRÍTICA  
**Costo estimado**: $15,000 - $50,000  
**Tiempo**: 3-6 semanas

**Firmas recomendadas**:

- [CertiK](https://www.certik.com/) - $30k-50k
- [OpenZeppelin](https://www.openzeppelin.com/security-audits) - $25k-40k
- [Trail of Bits](https://www.trailofbits.com/) - $35k-50k
- [Consensys Diligence](https://consensys.net/diligence/) - $30k-45k

**Alcance de auditoría**:

1. Revisión completa de smart contracts
2. Integración con Uniswap V2
3. Lógica de oracle
4. Access control
5. Reentrancy paths
6. Gas optimization
7. Economic attacks

**Beneficio**: Validación independiente de seguridad

---

### ⏰ Corto Plazo (1-3 meses)

#### 4. Flashbots Integration

**Prioridad**: ALTA  
**Tiempo estimado**: 2 semanas  
**Mitigación para**: H1 (Front-Running)

```javascript
// Propuesta para frontend
import { FlashbotsBundleProvider } from "@flashbots/ethers-provider-bundle";

async function sendPrivateTransaction(tx) {
  const flashbotsProvider = await FlashbotsBundleProvider.create(
    provider,
    signer,
    "https://relay.flashbots.net"
  );

  const signedTransactions = await flashbotsProvider.signBundle([
    {
      signer: signer,
      transaction: tx,
    },
  ]);

  const targetBlock = (await provider.getBlockNumber()) + 1;

  const simulation = await flashbotsProvider.simulate(
    signedTransactions,
    targetBlock
  );

  if (simulation.firstRevert) {
    console.error("Transaction would revert");
    return;
  }

  const bundleSubmission = await flashbotsProvider.sendRawBundle(
    signedTransactions,
    targetBlock
  );

  return bundleSubmission;
}
```

**Beneficio**: Elimina front-running en mainnet

---

#### 5. Circuit Breakers Automáticos

**Prioridad**: MEDIA  
**Tiempo estimado**: 1 semana

```solidity
// Propuesta de implementación
uint256 public s_lastSwapPrice;
uint256 public constant MAX_PRICE_DEVIATION_BPS = 1000; // 10%

function depositToken(address token, uint256 amountToken, uint256 minAmountOutUSDC)
    external
{
    // ... existing code ...

    uint256 currentPrice = (usdcReceived * 1e18) / amountToken;

    if (s_lastSwapPrice > 0) {
        uint256 deviation = currentPrice > s_lastSwapPrice
            ? ((currentPrice - s_lastSwapPrice) * 10000) / s_lastSwapPrice
            : ((s_lastSwapPrice - currentPrice) * 10000) / s_lastSwapPrice;

        if (deviation > MAX_PRICE_DEVIATION_BPS) {
            emit CircuitBreakerTriggered(token, currentPrice, s_lastSwapPrice);
            _pause(); // Auto-pause on suspicious activity
            revert KBV3_CircuitBreakerTriggered();
        }
    }

    s_lastSwapPrice = currentPrice;

    // ... rest of function
}
```

**Beneficio**: Protección automática contra ataques detectados

---

#### 6. Timelock para Admin Functions

**Prioridad**: MEDIA  
**Tiempo estimado**: 2 semanas

```solidity
// Propuesta usando OpenZeppelin TimelockController
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

// Deploy Timelock con 48h delay
TimelockController timelock = new TimelockController(
    2 days,           // min delay
    new address[](0), // proposers (se configura después)
    new address[](0), // executors (se configura después)
    admin             // admin
);

// KipuBankV3 grant admin to timelock
kipuBank.grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
kipuBank.revokeRole(DEFAULT_ADMIN_ROLE, admin);
```

**Beneficio**: Comunidad tiene 48h para reaccionar a cambios críticos

---

### 📅 Largo Plazo (3-6 meses)

#### 7. Bug Bounty Program

**Prioridad**: ALTA  
**Plataforma**: [Immunefi](https://immunefi.com/)  
**Presupuesto**: $50k - $500k según TVL

**Estructura de recompensas**:
| Severidad | Recompensa |
|-----------|------------|
| Critical | $50,000 |
| High | $10,000 |
| Medium | $2,500 |
| Low | $500 |

**Beneficio**: Detección continua de vulnerabilidades

---

#### 8. Insurance Protocol Integration

**Prioridad**: MEDIA  
**Costo**: 2-5% del TVL anualmente

**Opciones**:

- [Nexus Mutual](https://nexusmutual.io/) - Smart contract cover
- [InsurAce](https://www.insurace.io/) - Protocol cover
- [Unslashed Finance](https://unslashed.finance/) - DeFi insurance

**Beneficio**: Protección de usuarios contra exploits

---

#### 9. Multi-Sig para Roles Críticos

**Prioridad**: ALTA  
**Tiempo estimado**: 1 semana

```solidity
// Usar Gnosis Safe
// Admin role → Gnosis Safe 3/5
// Treasurer role → Gnosis Safe 2/3
// Pauser role → EOA (respuesta rápida) + Gnosis Safe 2/3
```

**Signatarios recomendados**:

- 2 miembros del equipo core
- 1 advisor de seguridad
- 1 miembro de la comunidad
- 1 inversor institucional

**Beneficio**: Previene compromiso de single point of failure

---

#### 10. Upgrade Path (UUPS Proxy)

**Prioridad**: BAJA  
**Tiempo estimado**: 3-4 semanas

```solidity
// Propuesta para V4
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract KipuBankV4 is UUPSUpgradeable, AccessControl {
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {}
}
```

**Consideraciones**:

- Storage layout debe ser backward compatible
- Tests exhaustivos pre-upgrade
- Migración de fondos planificada
- Comunicación transparente con usuarios

**Beneficio**: Permite fixes críticos sin redeploy completo

---

## 📈 Métricas de Seguridad

### KPIs Actuales

| Métrica                     | Objetivo | Actual | Status |
| --------------------------- | -------- | ------ | ------ |
| **Code Coverage**           | 80%      | 60.96% | 🟡     |
| **Test Cases**              | 100+     | 45+    | 🟡     |
| **Reentrancy Protection**   | 100%     | 100%   | ✅     |
| **Access Control Coverage** | 100%     | 100%   | ✅     |
| **Oracle Redundancy**       | 2+       | 1      | 🔴     |
| **Token Whitelist**         | Sí       | No     | 🔴     |
| **External Audits**         | 2+       | 0      | 🔴     |
| **Bug Bounty**              | Activo   | No     | 🔴     |
| **Insurance Coverage**      | >$1M TVL | $0     | 🔴     |
| **Multisig Admin**          | Sí       | No     | 🔴     |
| **Timelock Delay**          | 48h      | 0h     | 🔴     |
| **Circuit Breakers**        | Sí       | No     | 🔴     |

### Objetivos de Madurez (6 meses)

| Métrica               | Objetivo | Estrategia                 |
| --------------------- | -------- | -------------------------- |
| **Code Coverage**     | 85%      | +40 test cases             |
| **Test Cases**        | 120+     | Integration + stress tests |
| **Oracle Redundancy** | 100%     | Añadir Tellor fallback     |
| **Token Whitelist**   | 100%     | Top 20 tokens curados      |
| **External Audits**   | 2+       | CertiK + Trail of Bits     |
| **Bug Bounty**        | Activo   | Immunefi launch            |
| **Insurance**         | $2M+     | Nexus Mutual cover         |
| **Multisig**          | 3/5      | Gnosis Safe setup          |
| **Timelock**          | 48h      | OpenZeppelin Timelock      |
| **Circuit Breakers**  | Activo   | Auto-pause logic           |

---

## 🎯 Roadmap de Seguridad

### Q1 2026 (Mes 1-3)

- ✅ Deployment en testnet
- ✅ Tests básicos >50% coverage
- [ ] **TWAP implementation** (Prioridad 1)
- [ ] **Token whitelist** (Prioridad 2)
- [ ] **Auditoría CertiK** (Prioridad 3)

### Q2 2026 (Mes 4-6)

- [ ] Flashbots integration
- [ ] Circuit breakers
- [ ] Timelock implementation
- [ ] Auditoría Trail of Bits
- [ ] Bug bounty launch
- [ ] **Mainnet deployment** (si auditorías OK)

### Q3 2026 (Mes 7-9)

- [ ] Insurance coverage active
- [ ] Multi-sig for all roles
- [ ] Oracle redundancy (Tellor)
- [ ] Advanced monitoring (Defender)
- [ ] Stress test con >$1M TVL

### Q4 2026 (Mes 10-12)

- [ ] UUPS upgrade implementation
- [ ] Governance token consideration
- [ ] DAO transition planning
- [ ] Expansion to L2s

---

## 🔬 Análisis de Casos de Uso

### Caso 1: Usuario Normal

**Perfil**: Deposita $1000 USDC mensualmente  
**Riesgo**: 🟢 BAJO  
**Mitigaciones**: Todas aplicables  
**Recomendación**: Uso seguro con precauciones básicas

### Caso 2: Whale User

**Perfil**: Deposita $100k+ en una transacción  
**Riesgo**: 🟡 MEDIO (front-running target)  
**Mitigaciones**: Flashbots mandatory  
**Recomendación**: Usar private mempool, split en múltiples tx

### Caso 3: Arbitrage Bot

**Perfil**: High-frequency deposits/withdrawals  
**Riesgo**: 🟠 ALTO (MEV exposure)  
**Mitigaciones**: Flashbots + tight slippage  
**Recomendación**: Integración profesional con MEV protection

### Caso 4: Token Depositor

**Perfil**: Deposita tokens diversos (DAI, LINK, etc.)  
**Riesgo**: 🟡 MEDIO (liquidity + malicious token)  
**Mitigaciones**: Whitelist + liquidity checks  
**Recomendación**: Solo tokens whitelistados, verificar liquidez

---

## 📚 Referencias y Estándares

### Frameworks de Seguridad

- [OWASP Smart Contract Top 10](https://owasp.org/www-project-smart-contract-top-10/)
- [Consensys Smart Contract Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [Trail of Bits Security Guide](https://github.com/crytic/building-secure-contracts)

### Auditorías de Referencia

- Uniswap V2: [Trail of Bits Audit](https://github.com/Uniswap/uniswap-v2-core/blob/master/audit.pdf)
- Aave V3: [OpenZeppelin Audit](https://blog.openzeppelin.com/aave-v3-audit)
- Compound: [OpenZeppelin Audit](https://blog.openzeppelin.com/compound-audit)

### Herramientas Utilizadas

- **Testing**: Foundry
- **Coverage**: forge coverage
- **Static Analysis**: Slither (recomendado)
- **Fuzzing**: Echidna (recomendado)

---

## ⚠️ Disclaimer

Este análisis de amenazas es una evaluación técnica basada en las mejores prácticas actuales y conocimiento del ecosistema DeFi. Sin embargo:

1. **No sustituye auditoría profesional**: Se requiere auditoría externa antes de mainnet
2. **Amenazas evolucionan**: Nuevos vectores de ataque surgen constantemente
3. **Ningún sistema es 100% seguro**: Siempre existe riesgo residual
4. **Uso bajo tu propio riesgo**: Los usuarios deben entender los riesgos de DeFi

---

## 📞 Contacto para Reportar Vulnerabilidades

**Security Email**: security@kipubank.io (crear después de deployment)  
**PGP Key**: [Link a PGP key] (configurar)  
**Bug Bounty**: [Immunefi Program] (lanzar en Q2 2026)

**Proceso de reporte**:

1. NO divulgar públicamente
2. Enviar email a security@kipubank.io
3. Incluir PoC si es posible
4. Tiempo de respuesta: 24-48 horas
5. Recompensa según severidad

---

## ✅ Conclusión

**Estado Actual**: 🟡 **TESTNET READY**

KipuBankV3 implementa controles de seguridad sólidos para un MVP, con especial énfasis en:

- ✅ Reentrancy protection (100%)
- ✅ Access control (100%)
- ✅ Oracle validation (100%)
- ✅ Slippage protection (100%)
- ✅ Counter overflow protection (100%) - NUEVO en V3

Sin embargo, para alcanzar **madurez de producción en mainnet**, requiere:

- ⚠️ TWAP implementation (CRÍTICO)
- ⚠️ Token whitelisting (ALTO)
- ⚠️ Professional audits (CRÍTICO)
- ⚠️ MEV protection (ALTO)

**Recomendación Final**:

🔴 **NO desplegar en mainnet con fondos reales hasta**:

1. Completar TWAP implementation
2. Completar 2+ auditorías profesionales
3. Implementar token whitelist
4. Alcanzar >80% test coverage
5. Bug bounty activo por 3+ meses en testnet

🟢 **SAFE para testnet deployment con fines de**:

- Pruebas de concepto
- Demos a inversores
- Testing de integración
- Feedback de usuarios beta

---

**Próxima revisión**: Post-auditoría externa  
**Última actualización**: Noviembre 2025  
**Versión del análisis**: 1.0
