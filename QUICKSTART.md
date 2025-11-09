# ⚡ Quick Start Guide - KipuBankV3

## 🎯 Objetivo

Esta guía te llevará desde cero hasta tener **KipuBankV3** desplegado y testeado en **Sepolia testnet en 20 minutos**.

---

## 📋 Pre-requisitos

### 1. Instalar Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. Verificar instalación

```bash
forge --version
# Debe mostrar: forge 0.2.0 o superior

cast --version
# Debe mostrar: cast 0.2.0 o superior
```

### 3. Obtener ETH de testnet

- Ir a [Sepolia Faucet](https://sepoliafaucet.com/) o [Alchemy Sepolia Faucet](https://sepoliafaucet.com/)
- Pegar tu dirección de wallet
- Recibir 0.5 ETH (suficiente para deployment y pruebas)

**⚠️ Importante**: Usar una wallet nueva solo para testnet, NUNCA tu wallet principal.

---

## 🚀 Setup del Proyecto (5 minutos)

### Paso 1: Clonar e instalar dependencias

```bash
# Clonar repositorio
git clone https://github.com/tu-usuario/KipuBankV3.git
cd KipuBankV3

# Instalar dependencias de OpenZeppelin
forge install OpenZeppelin/openzeppelin-contracts@v4.9.3 --no-commit

# Instalar Chainlink
forge install smartcontractkit/chainlink-brownie-contracts@0.8.0 --no-commit

# Instalar Uniswap V2
forge install Uniswap/v2-periphery@1.1.0-beta.0 --no-commit

# Compilar contratos
forge build
```

**Salida esperada:**

```
[⠊] Compiling...
[⠒] Compiling 50 files with 0.8.26
[⠢] Solc 0.8.26 finished in 3.45s
Compiler run successful!
```

### Paso 2: Configurar variables de entorno

```bash
# Copiar template
cp .env.example .env

# Editar .env
nano .env
# O usar tu editor favorito: code .env, vim .env, etc.
```

**Contenido mínimo de `.env`:**

```env
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/TU_API_KEY
PRIVATE_KEY=tu_private_key_sin_0x
ETHERSCAN_API_KEY=tu_etherscan_api_key
```

**📝 Donde obtener las keys:**

1. **SEPOLIA_RPC_URL**:

   - Crear cuenta en [Alchemy](https://www.alchemy.com/)
   - Crear app → Seleccionar "Ethereum" → "Sepolia"
   - Copiar HTTP URL

2. **PRIVATE_KEY**:

   - MetaMask → Seleccionar wallet de testnet → Menú (3 puntos) → Account details → Export Private Key
   - **⚠️ NUNCA usar private key de tu wallet principal**
   - Copiar SIN el prefijo `0x`

3. **ETHERSCAN_API_KEY**:
   - Crear cuenta en [Etherscan](https://etherscan.io/register)
   - Ir a [API Keys](https://etherscan.io/myapikey)
   - Crear nuevo API Key

### Paso 3: Verificar configuración

```bash
# Cargar variables
source .env

# Verificar que se cargaron
echo $SEPOLIA_RPC_URL
# Debe mostrar tu URL completa

# Obtener dirección de la wallet
cast wallet address --private-key $PRIVATE_KEY
# Guarda esta dirección

# Verificar balance
cast balance $(cast wallet address --private-key $PRIVATE_KEY) --rpc-url $SEPOLIA_RPC_URL
# Debe mostrar > 0 (en wei)

# Convertir a ETH
cast balance $(cast wallet address --private-key $PRIVATE_KEY) --rpc-url $SEPOLIA_RPC_URL | cast --to-unit ether
# Debe mostrar algo como: 0.500000000000000000 ETH
```

---

## 🧪 Ejecutar Tests (5 minutos)

### Tests básicos

```bash
forge test
```

**Salida esperada:**

```
Running 45 tests for test/KipuBankV3.t.sol:KipuBankV3Test
[PASS] test_Deployment() (gas: 1234567)
[PASS] test_DepositETH() (gas: 234567)
[PASS] test_DepositUSDC() (gas: 345678)
...
Test result: ok. 45 passed; 0 failed; finished in 12.34s
```

### Tests con verbosidad (ver logs detallados)

```bash
forge test -vvv
```

### Tests específicos

```bash
# Solo tests de depósitos
forge test --match-test test_Deposit

# Solo tests de ETH
forge test --match-test ETH

# Solo tests de withdrawals
forge test --match-test Withdraw
```

### Cobertura de código

```bash
forge coverage
```

**Salida esperada:**

```
| File             | % Lines        | % Statements   | % Branches     | % Funcs       |
|------------------|----------------|----------------|----------------|---------------|
| src/KipuBankV3.sol | 60.96% (278/456) | 62.50% (300/480) | 55.00% (44/80) | 75.00% (18/24) |
```

**✅ Si coverage es >50%, estás listo para desplegar!**

---

## 🚢 Deployment en Sepolia (5 minutos)

### Opción 1: Script Automatizado (Recomendado)

```bash
# Dry run (simulación sin gastar gas)
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
  --rpc-url $SEPOLIA_RPC_URL

# Si la simulación fue exitosa, deployment real:
forge script script/DeployKipuBankV3.s.sol:DeployKipuBankV3 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

**Salida esperada:**

```
===========================================
PRE-DEPLOYMENT CHECK
===========================================
Network: Sepolia Testnet
Deployer: 0xYourAddress
Deployer balance: 0.5 ETH
...
===========================================
DEPLOYMENT SUCCESSFUL
===========================================
Contract Address: 0x1234567890abcdef1234567890abcdef12345678
===========================================
```

**⚠️ MUY IMPORTANTE**: Guardar la dirección del contrato!

### Opción 2: Comando Manual

```bash
forge create --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    $(cast wallet address --private-key $PRIVATE_KEY) \
    0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 \
    0x694AA1769357215DE4FAC081bf1f309aDC325306 \
    0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008 \
    1000000000000 \
    10000000000 \
    100 \
  src/KipuBankV3.sol:KipuBankV3 \
  --verify
```

### Solución de Problemas Comunes

#### Error: "Insufficient funds"

```bash
# Verificar balance nuevamente
cast balance $(cast wallet address --private-key $PRIVATE_KEY) --rpc-url $SEPOLIA_RPC_URL

# Si es cero o muy bajo, obtener más ETH del faucet
```

#### Error: "Failed to verify contract"

```bash
# Verificar manualmente después (ver sección siguiente)
```

#### Error: "RPC URL not responding"

```bash
# Verificar conectividad
curl $SEPOLIA_RPC_URL

# Probar con otro RPC público
export SEPOLIA_RPC_URL="https://rpc.sepolia.org"
```

---

## ✅ Verificación del Deployment (2 minutos)

### 1. Verificación Automática

Si el `--verify` funcionó, deberías ver:

```
Submitting verification for [KipuBankV3] at address: 0x...
Submitted contract for verification:
        Response: `OK`
        GUID: `...`
        URL: https://sepolia.etherscan.io/address/0x...
Contract successfully verified
```

### 2. Verificación Manual (si falló la automática)

```bash
# Guardar dirección del contrato
export CONTRACT_ADDRESS=0xTU_DIRECCION_DEL_CONTRATO_AQUI

# Verificar manualmente
forge verify-contract \
  --chain-id 11155111 \
  --compiler-version v0.8.26+commit.8a97fa7a \
  $CONTRACT_ADDRESS \
  src/KipuBankV3.sol:KipuBankV3 \
  --watch \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### 3. Verificar en Etherscan

Abrir en navegador:

```
https://sepolia.etherscan.io/address/TU_DIRECCION_AQUI
```

Deberías ver:

- ✅ Checkmark verde "Contract Source Code Verified"
- ✅ Tab "Contract" con el código fuente
- ✅ Tabs "Read Contract" y "Write Contract"

### 4. Verificar configuración via CLI

```bash
# Variables útiles
export DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

# Verificar versión
cast call $CONTRACT_ADDRESS "VERSION()(string)" --rpc-url $SEPOLIA_RPC_URL
# Debe retornar: 3.0.0

# Verificar bank cap
cast call $CONTRACT_ADDRESS "s_bankCapUSD6()(uint256)" --rpc-url $SEPOLIA_RPC_URL
# Debe retornar: 1000000000000

# Verificar USDC address
cast call $CONTRACT_ADDRESS "USDC()(address)" --rpc-url $SEPOLIA_RPC_URL
# Debe retornar: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

# Verificar admin role
cast call $CONTRACT_ADDRESS \
  "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  $DEPLOYER \
  --rpc-url $SEPOLIA_RPC_URL
# Debe retornar: true

# Verificar estado pausable
cast call $CONTRACT_ADDRESS "paused()(bool)" --rpc-url $SEPOLIA_RPC_URL
# Debe retornar: false
```

---

## 🎮 Interacción Básica (3 minutos)

### 1. Depositar ETH via CLI

```bash
# Depositar 0.01 ETH
cast send $CONTRACT_ADDRESS \
  "depositETH()" \
  --value 0.01ether \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL

# Esperar confirmación (10-20 segundos)
```

**Verificar balance:**

```bash
cast call $CONTRACT_ADDRESS \
  "getBalanceUSD6(address,address)(uint256)" \
  $DEPLOYER \
  0x0000000000000000000000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL

# Ejemplo de salida: 30450000 (= 30.45 USD en USD-6)
```

### 2. Depositar ETH via Etherscan UI

1. Ir a `https://sepolia.etherscan.io/address/$CONTRACT_ADDRESS`
2. Click en tab **"Contract"**
3. Click en subtab **"Write Contract"**
4. Click **"Connect to Web3"** → Conectar MetaMask
5. Buscar función `depositETH`
6. Ingresar en `payableAmount (ether)`: `0.01`
7. Click **"Write"**
8. Confirmar transacción en MetaMask
9. Esperar confirmación

### 3. Ver tu balance via Etherscan

1. Click en subtab **"Read Contract"**
2. Buscar función `getBalanceUSD6`
3. Ingresar:
   - `user (address)`: Tu dirección (copiar de MetaMask)
   - `token (address)`: `0x0000000000000000000000000000000000000000` (para ETH)
4. Click **"Query"**
5. Ver resultado (ejemplo: `30450000` = 30.45 USD)

### 4. Retirar ETH

```bash
# Retirar 50% del balance
BALANCE=$(cast call $CONTRACT_ADDRESS \
  "getBalanceUSD6(address,address)(uint256)" \
  $DEPLOYER \
  0x0000000000000000000000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL)

HALF_BALANCE=$((BALANCE / 2))

cast send $CONTRACT_ADDRESS \
  "withdrawETH(uint256)" \
  $HALF_BALANCE \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 5. Obtener precio de ETH

```bash
cast call $CONTRACT_ADDRESS \
  "getETHPrice()(uint256,uint8)" \
  --rpc-url $SEPOLIA_RPC_URL

# Ejemplo: 250000000000,8
# Significa: $2500.00 (8 decimales)
```

---

## 🐛 Troubleshooting

### Error: "Insufficient funds for gas"

```bash
# Verificar balance
cast balance $DEPLOYER --rpc-url $SEPOLIA_RPC_URL

# Obtener más ETH del faucet si es necesario
```

### Error: "Transaction underpriced"

```bash
# Especificar gas price más alto
cast send $CONTRACT_ADDRESS "depositETH()" \
  --value 0.01ether \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --gas-price 2gwei
```

### Error: "Execution reverted: KBV3_ZeroAmount"

```bash
# Asegurarse de enviar valor > 0
# Para depositETH, usar --value
# Para depositUSDC, aprobar primero
```

### Tests fallan: "fork not found"

```bash
# Agregar RPC URL al comando
forge test --fork-url $SEPOLIA_RPC_URL -vvv
```

### Deployment falla: "Create collision"

```bash
# El contrato ya existe en esa dirección
# Usa un nonce diferente o una wallet diferente
```

---

## 📊 Checklist Final

Antes de entregar el proyecto:

- [ ] ✅ Tests ejecutan y pasan (`forge test`)
- [ ] ✅ Coverage >50% (`forge coverage`)
- [ ] ✅ Contrato desplegado en Sepolia
- [ ] ✅ Contrato verificado en Etherscan (checkmark verde)
- [ ] ✅ Probado deposit ETH exitoso
- [ ] ✅ Probado withdraw ETH exitoso
- [ ] ✅ Screenshot de Etherscan con contrato verificado
- [ ] ✅ Código subido a GitHub (repositorio público)
- [ ] ✅ README.md completo en repositorio
- [ ] ✅ URL de Etherscan copiada (con https://)

---

## 📝 Información para Entrega

Una vez completado todo:

### 1. Información del Contrato

```
Dirección del contrato: 0x...
URL de Etherscan: https://sepolia.etherscan.io/address/0x...
Network: Sepolia Testnet (Chain ID: 11155111)
Deployer: 0x...
```

### 2. Comandos útiles para guardar

```bash
# Ver contrato en Etherscan
open https://sepolia.etherscan.io/address/$CONTRACT_ADDRESS

# Verificar balance
cast call $CONTRACT_ADDRESS "getBalanceUSD6(address,address)(uint256)" \
  TU_ADDRESS \
  0x0000000000000000000000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL

# Depositar más ETH
cast send $CONTRACT_ADDRESS "depositETH()" \
  --value 0.1ether \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## 🎓 Próximos Pasos

Una vez que todo funcione:

1. **Experimenta**:

   - Deposita diferentes cantidades
   - Prueba retiros parciales
   - Verifica los counters

2. **Mejora el código**:

   - Agrega más tests
   - Implementa nuevas features
   - Optimiza gas

3. **Comparte**:
   - Sube a GitHub
   - Documenta bien
   - Comparte con la comunidad

---

## 🆘 Soporte

Si encuentras problemas:

1. Revisa la sección de Troubleshooting
2. Busca el error en [Foundry Book](https://book.getfoundry.sh/)
3. Pregunta en Discord de Kipu
4. Revisa [GitHub Issues](https://github.com/foundry-rs/foundry/issues)

---

**¡Felicitaciones! 🎉 Has desplegado exitosamente KipuBankV3!**

Tu contrato DeFi está ahora funcionando en Sepolia testnet con integración completa de Uniswap V2.
