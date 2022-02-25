// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "./abstract/ReaperBaseStrategy.sol";
import "./interfaces/IUniswapRouter.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IMoneyPot.sol";
import "./interfaces/IZap.sol";
import "./interfaces/IElectronToken.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/**
 * @dev This strategy will farm LPs on Protofi and autocompound rewards
 */
contract ReaperAutoCompoundProtofiNucleus is ReaperBaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps. Also used to charge fees on yield.
     * {ELECTRON} - The reward token for farming
     * {PROTON} - Token gained from swapping Electron, to be converted to LP
     * {want} - The vault token the strategy is maximizing
     * {lpToken0} - Token 0 of the LP want token
     * {lpToken1} - Token 1 of the LP want token
     */
    address public constant WFTM = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    address public constant ELECTRON = 0x622265EaB66A45FA05bAc9B8d2262AA548FA449E;
    address public constant PROTON = 0xa23c4e69e5Eaf4500F2f9301717f12B578b948FB;
    address public want;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {PROTOFI_ROUTER} - The Protofi router
     * {MASTER_CHEF} - The Protofi MasterChef contract, used for staking the LPs for rewards
     * {MONEY_POT} - The Protofi MoneyPot contract, used for staking Electron to farm secondary rewards
     */
    address public constant PROTOFI_ROUTER = 0xF4C587a0972Ac2039BFF67Bc44574bB403eF5235;
    address public constant MASTER_CHEF = 0xa71f52aee8311c22b6329EF7715A5B8aBF1c6588;
    address public constant MONEY_POT = 0x180B3622BcC123e900E5eB603066755418d0b4F5;
    address public constant ZAP = 0xF0ff07d19f310abab54724a8876Eee71E338c82F;

    /**
     * @dev Routes we take to swap tokens
     * {electronToWftmRoute} - Route we take to get from {ELECTRON} into {WFTM}.
     * {wftmToWantRoute} - Route we take to get from {WFTM} into {want}.
     * {wftmToLp0Route} - Route we take to get from {WFTM} into {lpToken0}.
     * {wftmToLp1Route} - Route we take to get from {WFTM} into {lpToken1}.
     */
    address[] public electronToWftmRoute;
    address[] public wftmToWantRoute;
    address[] public wftmToLp0Route;
    address[] public wftmToLp1Route;

    /**
     * @dev Protofi variables
     * {poolId} - The MasterChef poolId to stake LP token
     */
    uint256 public poolId;

    /**
     * @dev Strategy variables
     * {shouldSellElectron} - If Electron should be swapped to Proton and compounded or staked to earn secondary yield
     * {allowedElectronPenalty} - Swapping Electron -> Proton has up to 30% penalty so this is the max penalty to still allow a swap.
     *                            Denominated in units of 1e10.
     * {shouldClaimElectron} - If Electron should be claimed (which effects the swap penalty)
     */
    bool public shouldSellElectron;
    uint256 public allowedElectronPenalty;
    bool public shouldClaimElectron;

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address[] memory _feeRemitters,
        address[] memory _strategists,
        address _want,
        uint256 _poolId
    ) public initializer {
        __ReaperBaseStrategy_init(_vault, _feeRemitters, _strategists);
        want = _want;
        poolId = _poolId;
        electronToWftmRoute = [ELECTRON, WFTM];

        lpToken0 = IUniswapV2Pair(want).token0();
        lpToken1 = IUniswapV2Pair(want).token1();

        wftmToLp0Route = [WFTM, lpToken0];
        wftmToLp1Route = [WFTM, lpToken1];

        shouldSellElectron = true;
        //allowedElectronPenalty = 297996875000;
        allowedElectronPenalty = 300000000000; // 30%
        shouldClaimElectron = true;

        _giveAllowances();
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {want} from the ProtoFi MasterChef
     * The available {want} minus fees is returned to the vault.
     */
    function withdraw(uint256 _withdrawAmount) external {
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));

        if (wantBalance < _withdrawAmount) {
            IMasterChef(MASTER_CHEF).withdraw(poolId, _withdrawAmount - wantBalance);
            wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        }

        if (wantBalance > _withdrawAmount) {
            wantBalance = _withdrawAmount;
        }

        uint256 withdrawFee = (_withdrawAmount * securityFee) / PERCENT_DIVISOR;
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance - withdrawFee);
    }

    /**
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     */
    function estimateHarvest() external view override returns (uint256 profit, uint256 callFeeToUser) {
        (, uint256 rewardDebt) = IMoneyPot(MONEY_POT).userInfo(address(this));
        IERC20Upgradeable rewardToken = IMoneyPot(MONEY_POT).rewardToken();
        if (rewardDebt != 0) {
            address[] memory rewardToWftmPath = new address[](2);
            rewardToWftmPath[0] = address(rewardToken);
            rewardToWftmPath[1] = WFTM;
            uint256[] memory amountOutMins = IUniswapRouter(PROTOFI_ROUTER).getAmountsOut(rewardDebt, rewardToWftmPath);
            profit += amountOutMins[1];
        }

        uint256 penaltyPercent = IElectronToken(ELECTRON).getPenaltyPercent(address(this));
        if (penaltyPercent <= allowedElectronPenalty) {
            uint256 pendingElectron = IMasterChef(MASTER_CHEF).pendingProton(poolId, address(this));
            uint256 electronBalance = IElectronToken(ELECTRON).balanceOf(address(this));
            uint256 totalElectron = electronBalance + pendingElectron;
            uint256 protonAmount = 0;
            if (penaltyPercent == 0) {
                protonAmount = totalElectron;
            } else {
                protonAmount = totalElectron - ((totalElectron * penaltyPercent) / 1e12);
            }
            if (protonAmount != 0) {
                address[] memory protonToWftmPath = new address[](2);
                protonToWftmPath[0] = PROTON;
                protonToWftmPath[1] = WFTM;
                uint256[] memory protonAmountOutMins = IUniswapRouter(PROTOFI_ROUTER).getAmountsOut(
                    protonAmount,
                    protonToWftmPath
                );
                profit += protonAmountOutMins[1];
            }
        }

        uint256 wftmFee = (profit * totalFee) / PERCENT_DIVISOR;
        callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
        profit -= wftmFee;
    }

    /**
     * @dev Sets if the Electron rewards should be sold and compounded or staked to earn protocol revenue
     */
    function setShouldSellElectron(bool _shouldSellElectron) external {
        _onlyStrategistOrOwner();
        shouldSellElectron = _shouldSellElectron;
    }

    /**
     * @dev Sets the tolerated penalty level where the strategy will swap Electron into Proton to compound rewards
     */
    function setAllowedElectronPenalty(uint256 _allowedElectronPenalty) external {
        _onlyStrategistOrOwner();
        require(_allowedElectronPenalty <= 300000000000);
        allowedElectronPenalty = _allowedElectronPenalty;
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
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);
    }

    /**
     * @dev Pauses supplied. Withdraws all funds from the ProtoFi MasterChef, leaving rewards behind.
     */
    function panic() external {
        _onlyStrategistOrOwner();
        IMasterChef(MASTER_CHEF).emergencyWithdraw(poolId);
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
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
     * It supplies {want} to farm {ELECTRON}
     */
    function deposit() public whenNotPaused {
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IMasterChef(MASTER_CHEF).deposit(poolId, wantBalance);
    }

    /**
     * @dev Calculates the total amount of {want} held by the strategy
     * which is the balance of want + the total amount supplied to ProtoFi.
     */
    function balanceOf() public view override returns (uint256) {
        return balanceOfWant() + balanceOfPool();
    }

    /**
     * @dev Calculates the total amount of {want} held in the ProtoFi MasterChef
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(MASTER_CHEF).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev Calculates the balance of want held directly by the strategy
     */
    function balanceOfWant() public view returns (uint256) {
        return IERC20Upgradeable(want).balanceOf(address(this));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. Claims {ELECTRON} from the MasterChef.
     * 2. Swaps {ELECTRON} to {WFTM}.
     * 3. Claims fees for the harvest caller and treasury.
     * 4. Swaps the {WFTM} token for {want}
     * 5. Deposits.
     */
    function _harvestCore() internal override {
        _claimRewards();
        if (shouldSellElectron) {
            _sellAndClaimElectron();
        } else {
            _stakeElectron();
        }
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
     * Compounds Electron into the want LP
     */
    function _sellAndClaimElectron() internal {
        uint256 penaltyPercent = IElectronToken(ELECTRON).getPenaltyPercent(address(this));
        if (penaltyPercent <= allowedElectronPenalty) {
            uint256 electronBalance = IElectronToken(ELECTRON).balanceOf(address(this));
            IElectronToken(ELECTRON).swapToProton(electronBalance);
            shouldClaimElectron = true;
        }
        if (shouldClaimElectron) {
            IMoneyPot(MONEY_POT).deposit(0);
            shouldClaimElectron = false;
        }
    }

    /**
     * @dev Core harvest function.
     * Stakes Electron in the MoneyPot
     */
    function _stakeElectron() internal {
        uint256 electronBalance = IERC20Upgradeable(ELECTRON).balanceOf(address(this));
        IMoneyPot(MONEY_POT).deposit(electronBalance);
    }

    /**
     * @dev Core harvest function.
     * Swaps {PROTO} to {WFTM}
     */
    function _swapRewardsToWftm() internal {
        IERC20Upgradeable rewardToken = IMoneyPot(MONEY_POT).rewardToken();
        uint256 moneyPotRewardBalance = rewardToken.balanceOf(address(this));
        if (moneyPotRewardBalance != 0) {
            address[] memory rewardToWftmPath = new address[](2);
            rewardToWftmPath[0] = address(rewardToken);
            rewardToWftmPath[1] = WFTM;
            IUniswapRouter(PROTOFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                moneyPotRewardBalance,
                0,
                rewardToWftmPath,
                address(this),
                block.timestamp
            );
        }
        uint256 protonBalance = IERC20Upgradeable(PROTON).balanceOf(address(this));
        if (protonBalance != 0) {
            address[] memory protonToWftmPath = new address[](2);
            protonToWftmPath[0] = PROTON;
            protonToWftmPath[1] = WFTM;
            IUniswapRouter(PROTOFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                protonBalance,
                0,
                protonToWftmPath,
                address(this),
                block.timestamp
            );
        }
        // IZap(ZAP).zapInToken(PROTON, protonBalance, want, PROTOFI_ROUTER, address(this));
        // zapInToken(address _from, uint amount, address _to, address routerAddr, address _recipient)
        //IZap(ZAP).zapInToken(rewardToken, moneyPotRewardBalance, want, PROTOFI_ROUTER, address(this));
    }

    /**
     * @dev Core harvest function.
     * Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal {
        uint256 wftmFee = (IERC20Upgradeable(WFTM).balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        if (wftmFee != 0) {
            uint256 callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
            uint256 treasuryFeeToVault = (wftmFee * treasuryFee) / PERCENT_DIVISOR;
            uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
            treasuryFeeToVault -= feeToStrategist;

            IERC20Upgradeable(WFTM).safeTransfer(msg.sender, callFeeToUser);
            IERC20Upgradeable(WFTM).safeTransfer(treasury, treasuryFeeToVault);
            IERC20Upgradeable(WFTM).safeTransfer(strategistRemitter, feeToStrategist);
        }
    }

    /** @dev Converts WFTM to both sides of the LP token and builds the liquidity pair */
    function _addLiquidity() internal {
        uint256 wftmBalance = IERC20Upgradeable(WFTM).balanceOf(address(this));
        if (wftmBalance != 0) {
            IZap(ZAP).zapInToken(WFTM, wftmBalance, want, PROTOFI_ROUTER, address(this));
        }
    }

    /**
     * @dev Gives the necessary allowances
     */
    function _giveAllowances() internal {
        uint256 wantAllowance = type(uint256).max - IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF);
        IERC20Upgradeable(want).safeIncreaseAllowance(MASTER_CHEF, wantAllowance);
        uint256 electronAllowance = type(uint256).max - IERC20Upgradeable(ELECTRON).allowance(address(this), MONEY_POT);
        IERC20Upgradeable(ELECTRON).safeIncreaseAllowance(MONEY_POT, electronAllowance);
        uint256 wftmAllowance = type(uint256).max - IERC20Upgradeable(WFTM).allowance(address(this), ZAP);
        IERC20Upgradeable(WFTM).safeIncreaseAllowance(ZAP, wftmAllowance);
        address rewardToken = address(IMoneyPot(MONEY_POT).rewardToken());
        uint256 rewardAllowance = type(uint256).max -
            IERC20Upgradeable(rewardToken).allowance(address(this), PROTOFI_ROUTER);
        IERC20Upgradeable(rewardToken).safeIncreaseAllowance(PROTOFI_ROUTER, rewardAllowance);
        uint256 lp0Allowance = type(uint256).max - IERC20Upgradeable(lpToken0).allowance(address(this), PROTOFI_ROUTER);
        IERC20Upgradeable(lpToken0).safeIncreaseAllowance(PROTOFI_ROUTER, lp0Allowance);
        uint256 lp1Allowance = type(uint256).max - IERC20Upgradeable(lpToken1).allowance(address(this), PROTOFI_ROUTER);
        IERC20Upgradeable(lpToken1).safeIncreaseAllowance(PROTOFI_ROUTER, lp1Allowance);
    }

    /**
     * @dev Removes all allowance that were given
     */
    function _removeAllowances() internal {
        IERC20Upgradeable(want).safeDecreaseAllowance(
            MASTER_CHEF,
            IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF)
        );
        IERC20Upgradeable(ELECTRON).safeDecreaseAllowance(
            MONEY_POT,
            IERC20Upgradeable(ELECTRON).allowance(address(this), MONEY_POT)
        );
        IERC20Upgradeable(WFTM).safeDecreaseAllowance(
            PROTOFI_ROUTER,
            IERC20Upgradeable(WFTM).allowance(address(this), PROTOFI_ROUTER)
        );
        IERC20Upgradeable(lpToken0).safeDecreaseAllowance(
            PROTOFI_ROUTER,
            IERC20Upgradeable(lpToken0).allowance(address(this), PROTOFI_ROUTER)
        );
        IERC20Upgradeable(lpToken1).safeDecreaseAllowance(
            PROTOFI_ROUTER,
            IERC20Upgradeable(lpToken1).allowance(address(this), PROTOFI_ROUTER)
        );
    }
}
