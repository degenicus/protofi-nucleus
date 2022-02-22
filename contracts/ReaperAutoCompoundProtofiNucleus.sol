// SPDX-License-Identifier: MIT

import './abstract/ReaperBaseStrategy.sol';
import './interfaces/IUniswapRouter.sol';
import './interfaces/IMasterChef.sol';
import './interfaces/IUniswapV2Pair.sol';
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

pragma solidity 0.8.11;

/**
 * @dev This strategy will farm LPs on Protofi and autocompound rewards
 */
contract ReaperAutoCompoundProtofiNucleus is ReaperBaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps. Also used to charge fees on yield.
     * {PROTO} - The reward token for farming
     * {want} - The vault token the strategy is maximizing
     * {lpToken0} - Token 0 of the LP want token
     * {lpToken1} - Token 1 of the LP want token
     */
    address public constant WFTM = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    address public constant PROTO = 0xa23c4e69e5Eaf4500F2f9301717f12B578b948FB;
    address public want;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {PROTOFI_ROUTER} - The Protofi router
     * {MASTER_CHEF} - The Protofi MasterChef contract, used for staking the LPs for rewards
     */
    address public constant PROTOFI_ROUTER = 0xF4C587a0972Ac2039BFF67Bc44574bB403eF5235;
    address public constant MASTER_CHEF    = 0xa71f52aee8311c22b6329EF7715A5B8aBF1c6588;

    /**
     * @dev Routes we take to swap tokens
     * {protoToWftmRoute} - Route we take to get from {PROTO} into {WFTM}.
     * {wftmToWantRoute} - Route we take to get from {WFTM} into {want}.
     * {wftmToLp0Route} - Route we take to get from {WFTM} into {lpToken0}.
     * {wftmToLp1Route} - Route we take to get from {WFTM} into {lpToken1}.
     */
    address[] public protoToWftmRoute;
    address[] public wftmToWantRoute;
    address[] public wftmToLp0Route;
    address[] public wftmToLp1Route;

    /**
    * @dev Protofi variables
    * {poolId} - The MasterChef poolId to stake LP token
    */
    uint public poolId;

    /**
     * @dev Strategy variables
     * {minProtoToSell} - The minimum amount of reward token to swap (low or 0 amount could cause swap to revert and may not be worth the gas)
    */
    uint public minProtoToSell;

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address _want,
        uint _poolId
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists);
        want = _want;
        poolId = _poolId;
        protoToWftmRoute = [PROTO, WFTM];
        
        lpToken0 = IUniswapV2Pair(want).token0();
        lpToken1 = IUniswapV2Pair(want).token1();

        wftmToLp0Route = [WFTM, lpToken0];
        wftmToLp1Route = [WFTM, lpToken1];

        minProtoToSell = 1000;

        _giveAllowances();
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {want} from the ProtoFi MasterChef
     * The available {want} minus fees is returned to the vault.
     */
    function withdraw(uint _withdrawAmount) external {
        uint wantBalance = IERC20Upgradeable(want).balanceOf(address(this));

        if (wantBalance < _withdrawAmount) {
            IMasterChef(MASTER_CHEF).withdraw(poolId, _withdrawAmount - wantBalance);
            wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        }

        if (wantBalance > _withdrawAmount) {
            wantBalance = _withdrawAmount;
        }

        uint withdrawFee = _withdrawAmount * securityFee / PERCENT_DIVISOR;
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance - withdrawFee);
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest() external view override returns (uint profit, uint callFeeToUser) {
        uint pendingProtons = IMasterChef(MASTER_CHEF).pendingProton(poolId, address(this));
        profit = IUniswapRouter(PROTOFI_ROUTER).getAmountsOut(pendingProtons, protoToWftmRoute)[1];
        uint wftmFee = (profit * totalFee) / PERCENT_DIVISOR;
        callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
        profit -= wftmFee;
    }

    /**
     * @dev Sets the minimum reward the will be sold (too little causes revert from Uniswap)
     */
    function setMinProtoToSell(uint256 _minProtoToSell) external {
        _onlyStrategistOrOwner();
        minProtoToSell = _minProtoToSell;
    }
    
    /**
     * @dev Function to retire the strategy. Claims all rewards and withdraws
     *      all principal from external contracts, and sends everything back to
     *      the vault. Can only be called by strategist or owner.
     *
     * Note: this is not an emergency withdraw function. For that, see panic().
     */
    function retireStrat() external {
        _onlyStrategistOrOwner();
        _harvestCore();
        IMasterChef(MASTER_CHEF).withdraw(poolId, balanceOfPool());
        uint wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
    }

    /**
     * @dev Pauses supplied. Withdraws all funds from the ProtoFi MasterChef, leaving rewards behind.
     */
    function panic() external {
        _onlyStrategistOrOwner();
        IMasterChef(MASTER_CHEF).emergencyWithdraw(poolId);
        uint wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
        pause();
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external {
        _onlyStrategistOrOwner();
        _unpause();

        _giveAllowances();

        deposit();
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public {
        _onlyStrategistOrOwner();
        _pause();
        _removeAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone supplied in the strategy's vault contract.
     * It supplies {want} to farm {PROTO}
     */
    function deposit() public whenNotPaused {
        uint wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IMasterChef(MASTER_CHEF).deposit(poolId, wantBalance);
    }

    /**
     * @dev Calculates the total amount of {want} held by the strategy
     * which is the balance of want + the total amount supplied to ProtoFi.
     */
    function balanceOf() public view override returns (uint) {
        return balanceOfWant() + balanceOfPool();
    }

    /**
     * @dev Calculates the total amount of {want} held in the ProtoFi MasterChef
     */
    function balanceOfPool() public view returns (uint) {
        (uint _amount, ) = IMasterChef(MASTER_CHEF).userInfo(
            poolId,
            address(this)
        );
        return _amount;
    }

    /**
     * @dev Calculates the balance of want held directly by the strategy
     */
    function balanceOfWant() public view returns (uint) {
        return IERC20Upgradeable(want).balanceOf(address(this));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. Claims {PROTO} from the MasterChef.
     * 2. Swaps {PROTO} to {WFTM}.
     * 3. Claims fees for the harvest caller and treasury.
     * 4. Swaps the {WFTM} token for {want}
     * 5. Deposits.
     */
    function _harvestCore() internal override {
        _claimRewards();
        _swapRewardsToWftm();
        _chargeFees();
        _addLiquidity();
        deposit();
    }

    /**
     * @dev Core harvest function.
     * Get rewards from the MasterChef
     */
    function _claimRewards() internal {
        IMasterChef(MASTER_CHEF).deposit(poolId, 0);
    }

    /**
     * @dev Core harvest function.
     * Swaps {PROTO} to {WFTM}
     */
    function _swapRewardsToWftm() internal {
        uint protoBalance = IERC20Upgradeable(PROTO).balanceOf(address(this));
        if (protoBalance >= minProtoToSell) {
            IUniswapRouter(PROTOFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                protoBalance,
                0,
                protoToWftmRoute,
                address(this),
                block.timestamp
            );
        }
    }

    /**
     * @dev Core harvest function.
     * Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal {
        uint wftmFee = (IERC20Upgradeable(WFTM).balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        if (wftmFee != 0) {
            uint callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
            uint treasuryFeeToVault = (wftmFee * treasuryFee) / PERCENT_DIVISOR;
            uint feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
            treasuryFeeToVault -= feeToStrategist;

            IERC20Upgradeable(WFTM).safeTransfer(msg.sender, callFeeToUser);
            IERC20Upgradeable(WFTM).safeTransfer(treasury, treasuryFeeToVault);
            IERC20Upgradeable(WFTM).safeTransfer(strategistRemitter, feeToStrategist);
        }
    }

    /** @dev Converts WFTM to both sides of the LP token and builds the liquidity pair */
    function _addLiquidity() internal {
        uint wrappedHalf = IERC20Upgradeable(WFTM).balanceOf(address(this)) / 2;
        if (wrappedHalf == 0) {
            return;
        }

        if (lpToken0 != WFTM) {
            IUniswapRouter(PROTOFI_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    wrappedHalf,
                    0,
                    wftmToLp0Route,
                    address(this),
                    block.timestamp
                );
        }
        if (lpToken1 != WFTM) {
            IUniswapRouter(PROTOFI_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    wrappedHalf,
                    0,
                    wftmToLp1Route,
                    address(this),
                    block.timestamp
                );
        }

        uint lp0Bal = IERC20Upgradeable(lpToken0).balanceOf(address(this));
        uint lp1Bal = IERC20Upgradeable(lpToken1).balanceOf(address(this));

        IUniswapRouter(PROTOFI_ROUTER).addLiquidity(
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            block.timestamp
        );
    }

    /**
     * @dev Gives the necessary allowances
     */
    function _giveAllowances() internal {
        uint wantAllowance = type(uint).max - IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF);
        IERC20Upgradeable(want).safeIncreaseAllowance(
            MASTER_CHEF,
            wantAllowance
        );
        uint protoAllowance = type(uint).max - IERC20Upgradeable(PROTO).allowance(address(this), PROTOFI_ROUTER);
        IERC20Upgradeable(PROTO).safeIncreaseAllowance(
            PROTOFI_ROUTER,
            protoAllowance
        );
        uint wftmAllowance = type(uint).max - IERC20Upgradeable(WFTM).allowance(address(this), PROTOFI_ROUTER);
        IERC20Upgradeable(WFTM).safeIncreaseAllowance(
            PROTOFI_ROUTER,
            wftmAllowance
        );
        uint lp0Allowance = type(uint).max - IERC20Upgradeable(lpToken0).allowance(address(this), PROTOFI_ROUTER);
        IERC20Upgradeable(lpToken0).safeIncreaseAllowance(
            PROTOFI_ROUTER,
            lp0Allowance
        );
        uint lp1Allowance = type(uint).max - IERC20Upgradeable(lpToken1).allowance(address(this), PROTOFI_ROUTER);
        IERC20Upgradeable(lpToken1).safeIncreaseAllowance(
            PROTOFI_ROUTER,
            lp1Allowance
        );
    }

    /**
     * @dev Removes all allowance that were given
     */
    function _removeAllowances() internal {
        IERC20Upgradeable(want).safeDecreaseAllowance(MASTER_CHEF, IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF));
        IERC20Upgradeable(PROTO).safeDecreaseAllowance(PROTOFI_ROUTER, IERC20Upgradeable(PROTO).allowance(address(this), PROTOFI_ROUTER));
        IERC20Upgradeable(WFTM).safeDecreaseAllowance(PROTOFI_ROUTER, IERC20Upgradeable(WFTM).allowance(address(this), PROTOFI_ROUTER));
        IERC20Upgradeable(lpToken0).safeDecreaseAllowance(PROTOFI_ROUTER, IERC20Upgradeable(lpToken0).allowance(address(this), PROTOFI_ROUTER));
        IERC20Upgradeable(lpToken1).safeDecreaseAllowance(PROTOFI_ROUTER, IERC20Upgradeable(lpToken1).allowance(address(this), PROTOFI_ROUTER));
    }
}
