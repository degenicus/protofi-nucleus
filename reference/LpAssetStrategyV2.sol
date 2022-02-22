// SPDX-License-Identifier: MIT

pragma solidity 0.6.2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface IUniSwapRouter {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

pragma solidity 0.6.2;

interface IUniswapV2Pair {
    function token0() external view returns (address);

    function token1() external view returns (address);
}

pragma solidity 0.6.2;

interface IMasterChef {
    function deposit(uint256 poolId, uint256 _amount) external;

    function withdraw(uint256 poolId, uint256 _amount) external;

    function userInfo(uint256 _pid, address _user)
        external
        view
        returns (uint256, uint256);

    function pendingProton(uint256 _pid, address _user)
        external
        view
        returns (uint256);

    function emergencyWithdraw(uint256 _pid) external;
}

pragma solidity 0.6.2;

contract LpAssetStrategyV2 is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens
    address public constant wrapped =
        address(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    address public output;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public masterchef;
    address public unirouter;
    address public wrappedToLp0Router;
    address public wrappedToLp1Router;
    address public outputToWrappedRouter;

    // Grim addresses
    address public constant harvester =
        address(0xb8924595019aFB894150a9C7CBEc3362999b9f94);
    address public constant treasury =
        address(0xfAE236b4E261278C2B84e74b4631cf7BCAFca06d);
    address public constant multisig =
        address(0x846eef31D340c1fE7D34aAd21499B427d5c12597);
    address public constant timelock =
        address(0x3040398Cfd9770BA613eA7223f61cc7D27D4037C);
    address public strategist;
    address public grimFeeRecipient;
    address public insuranceFund;
    address public sentinel;
    address public vault;

    // Numbers
    uint256 public poolId;

    // Routes
    address[] public outputToWrappedRoute;
    address[] public wrappedToLp0Route;
    address[] public wrappedToLp1Route;
    address[] customPath;

    // Controllers
    bool public harvestOnDeposit;

    // Fee structure
    uint256 public constant FEE_DIVISOR = 1000;
    uint256 public constant PLATFORM_FEE = 40; // 4% Platform fee
    uint256 public WITHDRAW_FEE = 1; // 0.1% of withdrawal amount
    uint256 public BUYBACK_FEE = 500; // 50% of Platform fee
    uint256 public TREASURY_FEE = 350; // 35% of Platform fee
    uint256 public CALL_FEE = 130; // 13% of Platform fee
    uint256 public STRATEGIST_FEE = 0; //  0% of Platform fee
    uint256 public INSURANCE_FEE = 20; //  2% of Platform fee

    event Harvest(address indexed harvester);
    event SetGrimFeeRecipient(address indexed newRecipient);
    event SetVault(address indexed newVault);
    event SetOutputToWrappedRoute(
        address[] indexed route,
        address indexed router
    );
    event SetWrappedToLp0Route(address[] indexed route, address indexed router);
    event SetWrappedToLp1Route(address[] indexed route, address indexed router);
    event RetireStrat(address indexed caller);
    event Panic(address indexed caller);
    event MakeCustomTxn(
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );
    event SetFees(uint256 indexed withdrawFee, uint256 indexed totalFees);
    event SetHarvestOnDeposit(bool indexed boolean);
    event StrategistMigration(
        bool indexed boolean,
        address indexed newStrategist
    );

    constructor(
        address _want,
        uint256 _poolId,
        address _masterChef,
        address _output,
        address _unirouter,
        address _sentinel,
        address _grimFeeRecipient,
        address _insuranceFund
    ) public {
        strategist = msg.sender;

        want = _want;
        poolId = _poolId;
        masterchef = _masterChef;
        output = _output;
        unirouter = _unirouter;
        sentinel = _sentinel;
        grimFeeRecipient = _grimFeeRecipient;
        insuranceFund = _insuranceFund;

        outputToWrappedRoute = [output, wrapped];
        outputToWrappedRouter = unirouter;
        wrappedToLp0Router = unirouter;
        wrappedToLp1Router = unirouter;

        lpToken0 = IUniswapV2Pair(want).token0();
        lpToken1 = IUniswapV2Pair(want).token1();

        wrappedToLp0Route = [wrapped, lpToken0];
        wrappedToLp1Route = [wrapped, lpToken1];

        harvestOnDeposit = false;
    }

    /** @dev Sets the grim fee recipient */
    function setGrimFeeRecipient(address _feeRecipient) external onlyOwner {
        grimFeeRecipient = _feeRecipient;

        emit SetGrimFeeRecipient(_feeRecipient);
    }

    /** @dev Sets the vault connected to this strategy */
    function setVault(address _vault) external onlyOwner {
        vault = _vault;

        emit SetVault(_vault);
    }

    /** @dev Function to synchronize balances before new user deposit. Can be overridden in the strategy. */
    function beforeDeposit() external virtual {}

    /** @dev Deposits funds into the masterchef */
    function deposit() public whenNotPaused {
        require(msg.sender == vault, "!auth");
        if (balanceOfPool() == 0 || !harvestOnDeposit) {
            _deposit();
        } else {
            _deposit();
            _harvest(msg.sender);
        }
    }

    function _deposit() internal whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        approveTxnIfNeeded(want, masterchef, wantBal);
        IMasterChef(masterchef).deposit(poolId, wantBal);
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount) {
            IMasterChef(masterchef).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        uint256 withdrawalFeeAmount = wantBal.mul(WITHDRAW_FEE).div(
            FEE_DIVISOR
        );
        IERC20(want).safeTransfer(vault, wantBal.sub(withdrawalFeeAmount));
    }

    function harvest() external {
        require(msg.sender == tx.origin, "!auth Contract Harvest");
        _harvest(msg.sender);
    }

    /** @dev Compounds the strategy's earnings and charges fees */
    function _harvest(address caller) internal whenNotPaused {
        if (caller != vault) {
            require(!Address.isContract(msg.sender), "!auth Contract Harvest");
        }
        IMasterChef(masterchef).deposit(poolId, 0);
        if (balanceOf() != 0) {
            chargeFees(caller);
            addLiquidity();
        }
        _deposit();

        emit Harvest(caller);
    }

    /** @dev This function converts all funds to WFTM, charges fees, and sends fees to respective accounts */
    function chargeFees(address caller) internal {
        uint256 toWrapped = IERC20(output).balanceOf(address(this));

        approveTxnIfNeeded(output, outputToWrappedRouter, toWrapped);

        IUniSwapRouter(outputToWrappedRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                toWrapped,
                0,
                outputToWrappedRoute,
                address(this),
                now
            );

        uint256 wrappedBal = IERC20(wrapped)
            .balanceOf(address(this))
            .mul(PLATFORM_FEE)
            .div(FEE_DIVISOR);

        uint256 callFeeAmount = wrappedBal.mul(CALL_FEE).div(FEE_DIVISOR);
        IERC20(wrapped).safeTransfer(caller, callFeeAmount);

        uint256 grimFeeAmount = wrappedBal.mul(BUYBACK_FEE).div(FEE_DIVISOR);
        IERC20(wrapped).safeTransfer(grimFeeRecipient, grimFeeAmount);

        uint256 treasuryAmount = wrappedBal.mul(TREASURY_FEE).div(FEE_DIVISOR);
        IERC20(wrapped).safeTransfer(treasury, treasuryAmount);

        uint256 strategistFee = wrappedBal.mul(STRATEGIST_FEE).div(FEE_DIVISOR);
        IERC20(wrapped).safeTransfer(strategist, strategistFee);

        uint256 insuranceFee = wrappedBal.mul(INSURANCE_FEE).div(FEE_DIVISOR);
        IERC20(wrapped).safeTransfer(insuranceFund, insuranceFee);
    }

    /** @dev Converts WFTM to both sides of the LP token and builds the liquidity pair */
    function addLiquidity() internal {
        uint256 wrappedHalf = IERC20(wrapped).balanceOf(address(this)).div(2);

        approveTxnIfNeeded(wrapped, wrappedToLp0Router, wrappedHalf);
        approveTxnIfNeeded(wrapped, wrappedToLp1Router, wrappedHalf);

        if (lpToken0 != wrapped) {
            IUniSwapRouter(wrappedToLp0Router)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    wrappedHalf,
                    0,
                    wrappedToLp0Route,
                    address(this),
                    now
                );
        }
        if (lpToken1 != wrapped) {
            IUniSwapRouter(wrappedToLp1Router)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    wrappedHalf,
                    0,
                    wrappedToLp1Route,
                    address(this),
                    now
                );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));

        approveTxnIfNeeded(lpToken0, unirouter, lp0Bal);
        approveTxnIfNeeded(lpToken1, unirouter, lp1Bal);

        IUniSwapRouter(unirouter).addLiquidity(
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            now
        );
    }

    /** @dev Determines the amount of reward in WFTM upon calling the harvest function */
    function callReward() public view returns (uint256) {
        uint256 outputBal = IMasterChef(masterchef).pendingProton(
            poolId,
            address(this)
        );
        uint256 nativeOut;

        if (outputBal > 0) {
            uint256[] memory amountsOut = IUniSwapRouter(unirouter)
                .getAmountsOut(outputBal, outputToWrappedRoute);
            nativeOut = amountsOut[amountsOut.length - 1];
        }

        return
            nativeOut.mul(PLATFORM_FEE).div(FEE_DIVISOR).mul(CALL_FEE).div(
                FEE_DIVISOR
            );
    }

    /** @dev calculate the total underlaying 'want' held by the strat */
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    /** @dev it calculates how much 'want' this contract holds */
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    /** @dev it calculates how much 'want' the strategy has working in the farm */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(
            poolId,
            address(this)
        );
        return _amount;
    }

    /** @dev called as part of strat migration. Sends all the available funds back to the vault */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");
        IMasterChef(masterchef).emergencyWithdraw(poolId);
        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);

        emit RetireStrat(msg.sender);
    }

    /** @dev Pauses the strategy contract and executes the emergency withdraw function */
    function panic() public {
        require(msg.sender == multisig || msg.sender == sentinel, "!auth");
        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId);

        emit Panic(msg.sender);
    }

    /** @dev Pauses the strategy contract */
    function pause() public {
        require(msg.sender == multisig || msg.sender == sentinel, "!auth");
        _pause();
        _removeAllowances();
    }

    /** @dev Unpauses the strategy contract */
    function unpause() external {
        require(msg.sender == multisig || msg.sender == sentinel, "!auth");
        _unpause();
        _deposit();
    }

    /** @dev Removes allowances to spenders */
    function _removeAllowances() internal {
        IERC20(want).safeApprove(masterchef, 0);
        IERC20(output).safeApprove(outputToWrappedRouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    /** @dev This function exists incase tokens that do not match the {want} of this strategy accrue.  For example: an amount of
    tokens sent to this address in the form of an airdrop of a different token type.  This will allow Grim to convert
    said token to the {want} token of the strategy, allowing the amount to be paid out to stakers in the matching vault. */
    function makeCustomTxn(address[] calldata _path, uint256 _amount)
        external
        onlyOwner
    {
        require(
            _path[0] != output && _path[_path.length - 1] == output,
            "Bad path || !auth"
        );

        approveTxnIfNeeded(_path[0], unirouter, _amount);

        IUniSwapRouter(unirouter).swapExactTokensForTokens(
            _amount,
            0,
            _path,
            address(this),
            now.add(600)
        );

        emit MakeCustomTxn(_path[0], _path[_path.length - 1], _amount);
    }

    /** @dev Modular function to set the output to wrapped route */
    function setOutputToWrappedRoute(address[] calldata _route, address _router)
        external
        onlyOwner
    {
        require(
            _route[0] == output && _route[_route.length - 1] == wrapped,
            "Bad path || !auth"
        );

        outputToWrappedRoute = _route;
        outputToWrappedRouter = _router;

        emit SetOutputToWrappedRoute(_route, _router);
    }

    /** @dev Modular function to set the transaction route of LP token 0 */
    function setWrappedToLp0Route(address[] calldata _route, address _router)
        external
        onlyOwner
    {
        require(
            _route[0] == wrapped && _route[_route.length - 1] == lpToken0,
            "Bad path || !auth"
        );

        wrappedToLp0Route = _route;
        wrappedToLp0Router = _router;

        emit SetWrappedToLp0Route(_route, _router);
    }

    /** @dev Modular function to set the transaction route of LP token 1 */
    function setWrappedToLp1Route(address[] calldata _route, address _router)
        external
        onlyOwner
    {
        require(
            _route[0] == wrapped && _route[_route.length - 1] == lpToken1,
            "Bad path || !auth"
        );

        wrappedToLp1Route = _route;
        wrappedToLp1Router = _router;

        emit SetWrappedToLp1Route(_route, _router);
    }

    /** @dev Internal function to approve the transaction if the allowance is below transaction amount */
    function approveTxnIfNeeded(
        address _token,
        address _spender,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _spender) < _amount) {
            IERC20(_token).safeApprove(_spender, 0);
            IERC20(_token).safeApprove(_spender, uint256(-1));
        }
    }

    /** @dev Sets the fee amounts */
    function setFees(
        uint256 newCallFee,
        uint256 newStratFee,
        uint256 newWithdrawFee,
        uint256 newBuyBackFee,
        uint256 newInsuranceFee,
        uint256 newTreasuryFee
    ) external onlyOwner {
        require(newWithdrawFee <= 10, "Exceeds max || !auth");
        uint256 sum = newCallFee
            .add(newStratFee)
            .add(newBuyBackFee)
            .add(newInsuranceFee)
            .add(newTreasuryFee);
        require(sum <= FEE_DIVISOR, "Exceeds max");

        CALL_FEE = newCallFee;
        STRATEGIST_FEE = newStratFee;
        WITHDRAW_FEE = newWithdrawFee;
        BUYBACK_FEE = newBuyBackFee;
        TREASURY_FEE = newTreasuryFee;
        INSURANCE_FEE = newInsuranceFee;

        emit SetFees(newWithdrawFee, sum);
    }
}
