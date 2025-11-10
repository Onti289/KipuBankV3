# KipuBankV3

## Descripción General

**KipuBankV3** es una actualización del contrato **KipuBankV2**, diseñada para convertirlo en una aplicación **DeFi** más realista y funcional.  
Esta nueva versión introduce soporte para **depósitos en cualquier token ERC-20** soportado por **Uniswap V2**, los cuales son automáticamente **convertidos a USDC** dentro del contrato y acreditados al balance del usuario.  
Además, mantiene toda la lógica principal de la versión anterior: control de ownership, depósitos, retiros y límites globales de fondos (bank cap).

### Mejoras Implementadas

1. **Integración con Uniswap V2 Router**
   - Permite realizar swaps automáticos desde cualquier token ERC-20 a **USDC** al momento del depósito.
   - Los swaps se ejecutan utilizando el router de Uniswap V2 dentro del contrato, garantizando descentralización y compatibilidad.

2. **Depósitos Generalizados**
   - El contrato acepta:
     - Token nativo (ETH)
     - USDC (sin conversión)
     - Cualquier token ERC-20 con par directo a USDC en Uniswap V2  
   - Si el token no es USDC, se intercambia automáticamente a USDC antes de acreditar el saldo.

3. **Nuevo Sistema de Límite Global (Bank Cap en USDC)**
   - El `bankCap` se expresa en **USDC**.
   - Antes de acreditar un depósito, el contrato valida que el monto total en USDC no supere el límite.

4. **Función de Retiro en USDC**
   - Se agregó la función:
     ```solidity
     function withdrawUSDC(uint256 amount)
     ```
     que permite retirar directamente el balance del usuario en USDC.

---

## Motivación del Diseño

La meta principal fue **acercar el contrato a un entorno DeFi real**, donde los depósitos pueden venir de múltiples tokens y deben ser normalizados a una moneda estable.  
El uso de USDC como unidad base garantiza consistencia en los balances y facilita la implementación de un límite global (`bankCap`) que preserve la estabilidad del sistema.

---

## Instrucciones de Despliegue

### Prerrequisitos
- **Node.js** ≥ 18
- **Hardhat** o **Remix IDE**
- Acceso a una red compatible con Uniswap V2 (por ejemplo, Ethereum, Sepolia o Polygon)
- Dirección del **UniswapV2 Router** correspondiente a la red elegida.
- Dirección del token **USDC** de esa red.

### Despliegue (con Hardhat)
```bash
npm install
npx hardhat compile
npx hardhat run scripts/deploy.js --network sepolia
```
### Variables a configurar en el Constructor

| Parámetro        | Descripción                                                                              | Valor sugerido                               |
| ---------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------- |
| `_threshold`     | Límite máximo de retiro por transacción (en USDC). Ej: 10,000 USDC                       | `10000000000000000000`                       |
| `_bankCap`       | Límite total del banco (en USDC). Ej: 10,000 USDC                                        | `10000000000000000000`                       |
| `_priceFeed`     | Dirección del oráculo **Chainlink ETH/USD** en Sepolia                                   | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| `_usdc`          | Dirección del token **USDC** en Sepolia                                                  | `0x07865c6E87B9F70255377e024ace6630C1Eaa37F` |
| `_uniswapRouter` | Dirección del router **Uniswap V2** en Sepolia                                           | `0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3` |


---

## Interacción
1. **Depósito**
   
El usuario puede depositar:
- ETH mediante depositNative()
- USDC mediante depositUSDC(uint256 amount)
- Cualquier otro token ERC-20 mediante depositToken(address token, uint256 amount)
Si el token no es USDC, el contrato automáticamente ejecuta un swap a USDC y acredita el resultado.

2. **Retiro**
   
El usuario puede retirar su balance en USDC con:
withdrawUSDC(uint256 amount)

3. **Consultar Balance**
   
getBalance(address user)
Retorna el balance del usuario expresado en USDC.

---

## Decisiones de diseño y trade-offs

| Aspecto                | Decisión                                                | Trade-off                                                    |
| ---------------------- | ------------------------------------------------------- | ------------------------------------------------------------ |
| **Token base**         | USDC elegido como moneda estable de referencia          | Dependencia directa de la liquidez de USDC en Uniswap        |
| **Router**             | Uso del `IUniswapV2Router02` estándar                   | Menor control sobre las tarifas de swap                      |
| **Swaps automáticos**  | Conversión inmediata al depósito                        | Aumento de gas al depositar tokens distintos de USDC         |
| **Seguridad**          | Mantener la protección de ownership y evitar reentradas | Menor flexibilidad en ciertas operaciones, pero más robustez |
