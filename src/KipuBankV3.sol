//SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*///////////////////////
	Imports
///////////////////////*/
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*///////////////////////
	Interfaces
///////////////////////*/
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
   @title Contrato KipuBank.
   @author Lucas Ontiveros.
   @notice Este contrato es el trabajo final del Módulo 4 - Development Tooling & DeFi.
   @custom:security Este es un contrato educativo y no debe ser usado en producción.
 */

/* Minimal interface del router Uniswap V2*/
interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

contract KipuBank is Ownable, ReentrancyGuard {
    /*///////////////////////
        DECLARACIÓN DE TIPOS
    ///////////////////////*/
    ///@notice estructura para almacenar la información de cada cliente.
    struct Client {
        string name;
        uint256 registeredAt;
        bool isActive;
    }

    ///@notice enumeración para definir el tipo de operación (depósito o retiro).
    enum OperationType { DEPOSIT, WITHDRAWAL }
    
    /*///////////////////////
		Variables
	///////////////////////*/
    ///@notice variable inmutable para almacenar el umbral fijo de retiro máximo por transacción (EN USDC).
    uint256 immutable i_threshold;

    ///@notice variable inmutable para almacenar el límite global del banco en USDC.
    uint256 immutable i_bankCap;

    ///@notice variable para almacenar el saldo total del banco (EN USDC).
    uint256 private currentBalance;
    
    ///@notice variable para contar el numero total de depósitos.
    uint256 private countDeposits;

    ///@notice variable para contar el numero total de retiros.
    uint256 private countWithdrawals;

    ///@notice mapping para almacenar el saldo de cada usuario (EN USDC).
	mapping(address user => uint256 amount) public s_balances;

    ///@notice variable para almacenar la dirección del oráculo Chainlink (ETH/USD).
    AggregatorV3Interface internal priceFeed;

    ///@notice variable constante para manejar precisión decimal en conversiones.
    uint256 public constant DECIMALS = 1e18;

    ///@notice mapping anidado para registrar el historial de operaciones por usuario y tipo.
    mapping(address => mapping(OperationType => uint256[])) public s_history;

    ///@notice mapping para almacenar la información de los clientes.
    mapping(address => Client) public s_clients;

    ///@notice dirección del token USDC (estable) usado como moneda de cuenta dentro del banco.
    address public immutable i_usdc;

    ///@notice router de Uniswap V2 para ejecutar swaps.
    IUniswapV2Router02 public immutable uniswapRouter;
   
    /*///////////////////////
		Events
	///////////////////////*/
    ///@notice evento emitido cuando se recibe un nuevo depósito (monto en USDC).
	event KipuBank_DepositReceived(address indexed user, uint256 _amount);
    ///@notice evento emitido cuando se realiza un retiro exitosamente (monto en USDC).
    event KipuBank_SuccessfulWithdrawal(address indexed user, uint256 _amount);
    ///@notice evento emitido cuando se registra un nuevo cliente.
    event KipuBank_NewClientRegistered(address indexed user, string name);
    ///@notice evento emitido cuando se actualiza la dirección del oráculo.
    event KipuBank_OracleUpdated(address indexed updater, address newOracle);
    
    /*///////////////////////
		Errors
	///////////////////////*/
    ///@notice error emitido cuando se deposita o retira una cantidad igual 0.
    error KipuBank_WrongAmount(uint256 _amount);
    ///@notice error emitido cuando se intenta retirar un monto mayor al saldo disponible.
    error KipuBank_InsufficientBalance(uint256 _amount);
    ///@notice error emitido cuando se intenta retirar un monto mayor al umbral.
    error KipuBank_ExcessWithdrawal(uint256 threshold);
    ///@notice error emitido cuando se intenta realizar un depósito cuando se ha alcanzado el límite global de depósitos.
    error KipuBank_BankCapReached(uint256 bankCap);
    ///@notice error emitido cuando falla una transferencia.
    error KipuBank_TransferFailed();
    ///@notice error emitido cuando se intenta registrar un cliente ya existente.
    error KipuBank_ClientAlreadyRegistered(address user);
    ///@notice error emitido cuando se intenta usar un oráculo inválido.
    error KipuBank_InvalidOracleAddress(address oracle);
    ///@notice error emitido cuando el precio retornado por el oráculo es inválido.
    error KipuBank_InvalidPrice();
    ///@notice error emitido cuando las aprobaciones o transfers de ERC20 fallan.
    error KipuBank_TokenTransferFailed();
    ///@notice error emitido cuando el path de swap no termina en USDC.
    error KipuBank_InvalidSwapPath();
    ///@notice error emitido cuando se intenta retirar ETH (los retiros deben ser en USDC).
    error KipuBank_WithdrawalsOnlyInUSDC();

    /*///////////////////////
        Modifiers
    ///////////////////////*/
    ///@notice modificador para verificar que el monto a retirar o depositar no sea 0.
    modifier correctAmount(uint256 _amount){
        if (_amount == 0) revert KipuBank_WrongAmount(_amount);
        _;
    }

    ///@notice modificador para verificar que el monto a retirar no sea mayor que el saldo de la cuenta.
    modifier sufficientBalance(uint256 _amount){
        if (s_balances[msg.sender] < _amount) revert KipuBank_InsufficientBalance(_amount);
        _;
    }

    ///@notice modificador para verificar que el monto a retirar no sea mayor que el umbral de retiro.
    modifier withdrawalLimit(uint256 _amount){
        if (_amount > i_threshold) revert KipuBank_ExcessWithdrawal(i_threshold);
        _;
    }

    ///@notice modificador para verificar que no se supere el límite global de depósitos (bankCap en USDC).
    modifier bankCap(uint256 incomingUSDC){
        if (currentBalance + incomingUSDC > i_bankCap) revert KipuBank_BankCapReached(i_bankCap);
        _;
    }

    ///@notice modificador para verificar que el usuario no esté ya registrado.
    modifier notRegistered() {
        if (s_clients[msg.sender].isActive) revert KipuBank_ClientAlreadyRegistered(msg.sender);
        _;
    }

    ///@notice modificador para validar que el oráculo configurado no sea la dirección cero.
    modifier validOracle(address _oracle) {
        if (_oracle == address(0)) revert KipuBank_InvalidOracleAddress(_oracle);
        _;
    }

    ///@notice modificador para validar que el precio del oráculo sea válido.
    modifier validPrice(int256 _price) {
        if (_price <= 0) revert KipuBank_InvalidPrice();
        _;
    }

    /*///////////////////////
		Functions
	///////////////////////*/
    /**
     * @param _threshold máximo de retiro por transacción (expresado en USDC).
     * @param _bankCap límite total del banco (en USDC).
     * @param _priceFeed dirección del oráculo Chainlink ETH/USD.
     * @param _usdc dirección del token USDC a usar como moneda de cuenta.
     * @param _uniswapRouter dirección del router Uniswap V2.
     */
    constructor(
        uint256 _threshold,
        uint256 _bankCap,
        address _priceFeed,
        address _usdc,
        address _uniswapRouter
    ) Ownable(msg.sender) {
        i_threshold = _threshold;
        i_bankCap = _bankCap;
        priceFeed = AggregatorV3Interface(_priceFeed);
        i_usdc = _usdc;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);

        currentBalance = 0;
        countDeposits = 0;
        countWithdrawals = 0;
    }

    ///@notice función para recibir ether directamente. Se convierte a USDC y acredita.
    receive() external payable {
        depositEth();            
    }
    fallback() external payable{}

    /*
		*@notice función externa para depositar ETH en la cuenta (se convierte a USDC).
		*@dev realiza swap ETH -> USDC usando Uniswap V2 y acredita en USDC.
		*@dev respeta el bankCap en USDC antes de acreditar.
	*/
    function depositEth() public payable nonReentrant correctAmount(msg.value) {
        // Construir path WETH -> USDC
        address weth = uniswapRouter.WETH();
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = i_usdc;

        // Ejecutar swap ETH -> USDC
        uint256 deadline = block.timestamp + 300; // 5 minutos
        uint[] memory amounts = uniswapRouter.swapExactETHForTokens{value: msg.value}(
            0, // amountOutMin = 0
            path,
            address(this),
            deadline
        );

        uint256 usdcReceived = amounts[amounts.length - 1];

        // Verificar bankCap (USDC)
        if (currentBalance + usdcReceived > i_bankCap) revert KipuBank_BankCapReached(i_bankCap);

        // Acreditar saldo en USDC
        s_balances[msg.sender] += usdcReceived;
        currentBalance += usdcReceived;
        countDeposits += 1;

        ///@notice se agrega el registro de la operación en el historial del usuario.
        s_history[msg.sender][OperationType.DEPOSIT].push(usdcReceived);

        emit KipuBank_DepositReceived(msg.sender, usdcReceived);
    }

    /*
        *@notice función para depositar tokens ERC20 (si es distinto de USDC se convierte a USDC).
        *@param token la dirección del token depositado.
        *@param amount la cantidad de token a depositar (en la unidad del token).
        *@param amountOutMin mínimo aceptable de USDC esperado por el swap (para controlar slippage).
        *@param path ruta de swap (deben terminar en USDC).
        *@dev el path debe terminar en el token USDC registrado en el contrato.
    */
    function depositToken(
        address token,
        uint256 amount,
        uint256 amountOutMin,
        address[] calldata path
    ) external nonReentrant correctAmount(amount) {
        // Transferir tokens desde usuario al contrato
        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert KipuBank_TokenTransferFailed();

        uint256 usdcReceived;

        if (token == i_usdc) {
            // Si ya es USDC, no swap; simplemente usar el amount como USDC recibido.
            usdcReceived = amount;
        } else {
            // Validar que la ruta termine en USDC
            if (path.length == 0) revert KipuBank_InvalidSwapPath();
            if (path[path.length - 1] != i_usdc) revert KipuBank_InvalidSwapPath();

            // Aprobar router para gastar el token
            ok = IERC20(token).approve(address(uniswapRouter), amount);
            if (!ok) revert KipuBank_TokenTransferFailed();

            // Ejecutar swap token -> USDC
            uint256 deadline = block.timestamp + 300;
            uint[] memory amounts = uniswapRouter.swapExactTokensForTokens(
                amount,
                amountOutMin,
                path,
                address(this),
                deadline
            );

            usdcReceived = amounts[amounts.length - 1];
        }

        // Verificar bankCap (USDC)
        if (currentBalance + usdcReceived > i_bankCap) revert KipuBank_BankCapReached(i_bankCap);

        // Acreditar saldo en USDC
        s_balances[msg.sender] += usdcReceived;
        currentBalance += usdcReceived;
        countDeposits += 1;

        ///@notice se agrega el registro de la operación en el historial del usuario.
        s_history[msg.sender][OperationType.DEPOSIT].push(usdcReceived);

        emit KipuBank_DepositReceived(msg.sender, usdcReceived);
    }

    /*
		*@notice función para retirar ETH de la cuenta.
		*@dev ahora los retiros deben ser realizados en USDC mediante withdrawUSDC.
        *@dev esta función se mantiene por compatibilidad pero siempre revertirá.
	*/
    function withdrawEth(uint256 /* _amount */) external pure{
        //Los retiros son siempre en USDC.
        revert KipuBank_WithdrawalsOnlyInUSDC();
    }

    /*
		*@notice función para retirar USDC de la cuenta.
		*@dev esta función resta el valor del retiro al saldo del usuario (EN USDC).
        *@dev suma 1 al total de retiros.
        *@dev resta el valor del retiro al saldo del banco.
        *@dev transfiere USDC al usuario.
		*@dev emite un evento informando el retiro.
        *@dev emite un error si el importe es erróneo, saldo insuficiente o supera el umbral.
	*/
    function withdrawUSDC(uint256 _amount) external nonReentrant correctAmount(_amount) withdrawalLimit(_amount) sufficientBalance(_amount) {
        s_balances[msg.sender] -= _amount;
        currentBalance -= _amount;
        countWithdrawals += 1;

        ///@notice se agrega el registro de la operación en el historial del usuario.
        s_history[msg.sender][OperationType.WITHDRAWAL].push(_amount);

        emit KipuBank_SuccessfulWithdrawal(msg.sender, _amount);

        // Transferir USDC al usuario
        bool sent = IERC20(i_usdc).transfer(msg.sender, _amount);
        if (!sent) revert KipuBank_TransferFailed();
	}

    /*
		*@notice función para ver obtener el saldo de la cuenta ingresada por parámetro.
		*@dev esta función debe retornar el saldo cuenta ingresada por parámetro (EN USDC).
	*/
    function getUserBalance(address user) external view returns (uint256) {
        return s_balances[user];
    }

    /*
		*@notice función para ver obtener la cantidad total de depositos y retiros del banco.
		*@dev esta función debe retornar el numero total de depósitos y retiros del banco.
	*/
    function getTotals() external view returns (uint256 deposits, uint256 withdrawals) {
        return (countDeposits, countWithdrawals);
    }

    /*
		*@notice función para ver obtener el saldo total del banco (EN USDC).
		*@dev esta función debe retornar el saldo total del banco.
	*/
    function getBankBalance() external view returns (uint256) {
        return currentBalance;
    }

    ///@notice función restringida al propietario para actualizar la dirección del oráculo Chainlink.
    function updatePriceFeed(address _newFeed) external onlyOwner validOracle(_newFeed) {
        priceFeed = AggregatorV3Interface(_newFeed);
        emit KipuBank_OracleUpdated(msg.sender, _newFeed);
    }

    ///@notice función para registrar un nuevo cliente en el banco.
    function registerClient(string calldata _name) external notRegistered {
        s_clients[msg.sender] = Client(_name, block.timestamp, true);
        emit KipuBank_NewClientRegistered(msg.sender, _name);
    }

    ///@notice función para obtener el precio actual de ETH/USD desde el oráculo Chainlink.
    function getLatestETHPrice() public view returns (int256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        return price;
    }

    ///@notice función para convertir un monto en wei a USD usando el oráculo de Chainlink.
    ///@dev conserva utilidad informativa aunque las operaciones de swap las hace Uniswap.
    function convertEthToUSD(uint256 ethAmountWei) public view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        if (price <= 0) revert KipuBank_InvalidPrice();
        uint256 ethInUSD = (ethAmountWei * uint256(price)) / (10 ** 8);
        return ethInUSD;
    }

    ///@notice función para convertir un monto en USD a wei (ETH) usando el oráculo de Chainlink.
    function convertUSDToEth(uint256 usdAmount) public view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        if (price <= 0) revert KipuBank_InvalidPrice();
        uint256 ethWei = (usdAmount * (10 ** 8)) / uint256(price);
        return ethWei;
    }
}
