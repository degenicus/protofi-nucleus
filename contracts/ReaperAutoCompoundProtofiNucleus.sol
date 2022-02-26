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

    // full 30% penalty when immediately swapping ELCT -> PROTO
    uint256 public constant AFTER_PENALTY = 70_000;

    /**
     * @dev Tokens Used:
     * {WFTM} - Required for liquidity routing when doing swaps. Also used to charge fees on yield.
     * {ELCT} - The reward token for farming
     * {PROTO} - Token gained from swapping ELCT, to be converted to LP
     * {want} - The vault token the strategy is maximizing
     */
    address public constant WFTM = 0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83;
    address public constant ELCT = 0x622265EaB66A45FA05bAc9B8d2262AA548FA449E;
    address public constant PROTO = 0xa23c4e69e5Eaf4500F2f9301717f12B578b948FB;
    address public want;

    /**
     * @dev Third Party Contracts:
     * {PROTOFI_ROUTER} - The Protofi router
     * {MASTER_CHEF} - The Protofi MasterChef contract, used for staking the LPs for rewards
     * {MONEY_POT_INITIAL} - The Protofi MoneyPot contract, used for staking ELCT to farm secondary rewards
     */
    address public constant PROTOFI_ROUTER = 0xF4C587a0972Ac2039BFF67Bc44574bB403eF5235;
    address public constant MASTER_CHEF = 0xa71f52aee8311c22b6329EF7715A5B8aBF1c6588;
    address public constant MONEY_POT_INITIAL = 0x180B3622BcC123e900E5eB603066755418d0b4F5;
    address public constant ZAP = 0xF0ff07d19f310abab54724a8876Eee71E338c82F;
    // TODO tess3rac7 MONEY_POT address can change?
    // Add new setter function that would move the entire deposit and update allowances
    // Also have the ability to set the path for the reward token and give allowances for it

    /**
     * @dev Routes we take to swap tokens
     * {protoToWftmRoute} - Route we take to get from {PROTO} into {WFTM}.
     * {rewardToWftmRoute} - Route we take to get from current MoneyPot's reward to {WFTM}.
     */
    address[] public protoToWftmRoute;
    address[] public rewardToWftmRoute;

    /**
     * @dev Protofi variables
     * {poolId} - The MasterChef poolId to stake LP token.
     * {moneyPotAddr} - Address of the MoneyPot instance currently in use by the strategy.
     */
    uint256 public poolId;
    address public moneyPotAddr;

    /**
     * @dev Strategy variables in basis points precision.
     * {MCEmissionsSellPercent} - % of Masterchef emissions (ELCT) to be immediately swapped for PROTO and recompounded.
     * {MPDepositSellPercent} - % of MoneyPot deposit (ELCT) to withdraw, immediately swap for PROTO, and recompound.
     */
    uint256 public MCEmissionsSellPercent;
    uint256 public MPDepositSellPercent;

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
        moneyPotAddr = MONEY_POT_INITIAL;
        protoToWftmRoute = [PROTO, WFTM];

        address rewardTokenAddr = address(IMoneyPot(moneyPotAddr).rewardToken());
        if (rewardTokenAddr == WFTM) {
            rewardToWftmRoute = [WFTM];
        } else {
            rewardToWftmRoute = [rewardTokenAddr, WFTM];
        }

        // to start, compound all MasterChef {ELCT} emissions with full 30% penalty
        MCEmissionsSellPercent = PERCENT_DIVISOR;
        MPDepositSellPercent = 0;

        _giveAllowances();
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It supplies {want} to farm {ELCT}
     */
    function deposit() public whenNotPaused {
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IMasterChef(MASTER_CHEF).deposit(poolId, wantBalance);
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {want} from the ProtoFi MasterChef
     * The available {want} minus fees is returned to the vault.
     */
    function withdraw(uint256 _withdrawAmount) external {
        require(msg.sender == vault, "!vault");
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
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. Claims various rewards and swap to {WFTM}.
     * 2. Charges performance fees from the {WFTM} balance.
     * 3. Swaps the remaining {WFTM} token for {want}.
     * 4. Invokes deposit().
     */
    function _harvestCore() internal override {
        _claimRewardsAndSwapToWftm();
        _chargeFees();
        _addLiquidity();
        deposit();
    }

    /**
     * @dev Core harvest function.
     * 1. Claims {ELCT} rewards from the MasterChef.
     * 2. Swaps {MCEmissionsSellPercent} of the claimed {ELCT} to {PROTO}.
     * 3. Withdraws {MPDepositSellPercent} of {ELCT} from the MoneyPot and swaps it to {PROTO}.
     * 4. Deposists any remaining {ELCT} into the MoneyPot.
     * 5. Swaps strategy's {PROTO} balance to {WFTM}.
     * 6. Claims {X} rewards from the MoneyPot (X is variable) and swap it {WFTM}.
     */
    function _claimRewardsAndSwapToWftm() internal {
        IElectronToken elct = IElectronToken(ELCT);
        IMasterChef masterChef = IMasterChef(MASTER_CHEF);
        IMoneyPot moneyPot = IMoneyPot(moneyPotAddr);

        masterChef.deposit(poolId, 0); // 1
        elct.swapToProton((elct.balanceOf(address(this)) * MCEmissionsSellPercent) / PERCENT_DIVISOR); // 2

        (uint256 MPDeposit, ) = moneyPot.userInfo(address(this));
        moneyPot.withdraw((MPDeposit * MPDepositSellPercent) / PERCENT_DIVISOR); // 3 + 6 (withdrawing claims rewards)

        moneyPot.deposit(elct.balanceOf(address(this))); // 4

        IUniswapRouter(PROTOFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20Upgradeable(PROTO).balanceOf(address(this)),
            0,
            protoToWftmRoute,
            address(this),
            block.timestamp
        ); // 5

        address rewardToken = rewardToWftmRoute[0];
        uint256 moneyPotRewardBalance = IERC20Upgradeable(rewardToken).balanceOf(address(this));
        if (moneyPotRewardBalance != 0 && rewardToWftmRoute.length > 1) {
            IUniswapRouter(PROTOFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                moneyPotRewardBalance,
                0,
                rewardToWftmRoute,
                address(this),
                block.timestamp
            );
        } // 6 (swap rewards to WFTM)
    }

    /**
     * @dev Core harvest function.
     * Charges fees based on the amount of WFTM gained from reward
     */
    function _chargeFees() internal {
        IERC20Upgradeable wftm = IERC20Upgradeable(WFTM);
        uint256 wftmFee = (wftm.balanceOf(address(this)) * totalFee) / PERCENT_DIVISOR;
        if (wftmFee != 0) {
            uint256 callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
            uint256 treasuryFeeToVault = (wftmFee * treasuryFee) / PERCENT_DIVISOR;
            uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
            treasuryFeeToVault -= feeToStrategist;

            wftm.safeTransfer(msg.sender, callFeeToUser);
            wftm.safeTransfer(treasury, treasuryFeeToVault);
            wftm.safeTransfer(strategistRemitter, feeToStrategist);
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
     * @dev Returns the approx amount of profit from harvesting.
     *      Profit is denominated in WFTM, and takes fees into account.
     *      Profit is made up of:
     *      1. {MPDepositSellPercent} of MoneyPot deposit (full 30% penalty applies)
     *      2. {MCEmissionsSellPercent} of MasterChef ELCT rewards (full 30% penalty applies)
     *      3. Full rewards from MoneyPot
     */
    function estimateHarvest() external view override returns (uint256 profit, uint256 callFeeToUser) {
        // 1
        (uint256 elctAmount, ) = IMoneyPot(moneyPotAddr).userInfo(address(this));
        elctAmount = (elctAmount * MPDepositSellPercent) / PERCENT_DIVISOR;

        // 2 (yes, function is called "pendingProton" even though reward could be ELCT or PROTO)
        elctAmount += IMasterChef(MASTER_CHEF).pendingProton(poolId, address(this));

        // 1 + 2
        if (elctAmount != 0) {
            uint256[] memory amountOutMins = IUniswapRouter(PROTOFI_ROUTER).getAmountsOut(
                (elctAmount * AFTER_PENALTY) / PERCENT_DIVISOR,
                protoToWftmRoute
            );
            profit += amountOutMins[1];
        }

        // 3
        uint256 rewardAmount = IMoneyPot(moneyPotAddr).pendingReward(address(this));
        if (rewardAmount != 0) {
            if (rewardToWftmRoute.length > 1) {
                uint256[] memory amountOutMins = IUniswapRouter(PROTOFI_ROUTER).getAmountsOut(
                    rewardAmount,
                    rewardToWftmRoute
                );
                profit += amountOutMins[1];
            } else {
                profit += rewardAmount;
            }
        }

        uint256 wftmFee = (profit * totalFee) / PERCENT_DIVISOR;
        callFeeToUser = (wftmFee * callFee) / PERCENT_DIVISOR;
        profit -= wftmFee;
    }

    /**
     * @dev Function to configure the strategy params {MCEmissionsSellPercent} and
     * {MPDepositSellPercent}. Can only be called by strategist or owner.
     */
    function setStratParams(uint256 _MCEmissionsSellPercent, uint256 _MPDepositSellPercent) external {
        _onlyStrategistOrOwner();
        require(_MCEmissionsSellPercent <= PERCENT_DIVISOR, "invalid _MCEmissionsSellPercent");
        require(_MPDepositSellPercent <= PERCENT_DIVISOR, "invalid _MPDepositSellPercent");
        MCEmissionsSellPercent = _MCEmissionsSellPercent;
        MPDepositSellPercent = _MPDepositSellPercent;
    }

    /**
     * @dev Function to update the {moneyPotAddr} used by the strategy, as well as
     * {rewardToWftmRoute}. Any deposits are moved to the new MoneyPot. Can only be
     * called by strategist or owner.
     */
    function updateMoneyPot(address _newMoneyPotAddr, address[] calldata _newRewardToWftmRoute) external {
        _onlyStrategistOrOwner();

        // Sanity checks
        IERC20Upgradeable newRewardToken = IMoneyPot(_newMoneyPotAddr).rewardToken();
        require(_newRewardToWftmRoute[0] == address(newRewardToken), "bad route");
        require(_newRewardToWftmRoute[_newRewardToWftmRoute.length - 1] == WFTM, "bad route");

        // Withdraw everything from current MoneyPot instance.
        // Also claims rewards that we should swap to WFTM and then just leave in the strategy.
        // This WFTM would get picked up in the next harvest.
        (uint256 elctAmount, ) = IMoneyPot(moneyPotAddr).userInfo(address(this));
        IMoneyPot(moneyPotAddr).withdraw(elctAmount);
        address rewardTokenAddr = rewardToWftmRoute[0];
        uint256 moneyPotRewardBalance = IERC20Upgradeable(rewardTokenAddr).balanceOf(address(this));
        if (moneyPotRewardBalance != 0 && rewardToWftmRoute.length > 1) {
            IUniswapRouter(PROTOFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                moneyPotRewardBalance,
                0,
                rewardToWftmRoute,
                address(this),
                block.timestamp
            );
        }

        // Remove old allowances
        IERC20Upgradeable elct = IERC20Upgradeable(ELCT);
        elct.safeDecreaseAllowance(moneyPotAddr, elct.allowance(address(this), moneyPotAddr));
        IERC20Upgradeable(rewardToWftmRoute[0]).safeDecreaseAllowance(
            PROTOFI_ROUTER,
            IERC20Upgradeable(rewardToWftmRoute[0]).allowance(address(this), PROTOFI_ROUTER)
        );

        // Update moneyPotAddr and rewardToWftmRoute and re-deposit into new MoneyPot
        moneyPotAddr = _newMoneyPotAddr;
        rewardToWftmRoute = _newRewardToWftmRoute;
        IMoneyPot(moneyPotAddr).deposit(elctAmount);

        // Add new allowances
        uint256 electronAllowance = type(uint256).max - elct.allowance(address(this), moneyPotAddr);
        elct.safeIncreaseAllowance(moneyPotAddr, electronAllowance);
        IERC20Upgradeable rewardToken = IERC20Upgradeable(rewardToWftmRoute[0]);
        uint256 rewardAllowance = type(uint256).max - rewardToken.allowance(address(this), PROTOFI_ROUTER);
        rewardToken.safeIncreaseAllowance(PROTOFI_ROUTER, rewardAllowance);
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

        // mini-harvest
        _claimRewardsAndSwapToWftm();
        _addLiquidity();

        IMasterChef(MASTER_CHEF).withdraw(poolId, balanceOfPool());
        uint256 wantBalance = IERC20Upgradeable(want).balanceOf(address(this));
        IERC20Upgradeable(want).safeTransfer(vault, wantBalance);

        // left-over {ELCT} in the MoneyPot can be remitted to treasury and strategists
        // reward was just claimed so only {ELCT} withdrawn now
        (uint256 elctAmount, ) = IMoneyPot(moneyPotAddr).userInfo(address(this));
        IMoneyPot(moneyPotAddr).withdraw(elctAmount);
        IElectronToken(ELCT).swapToProton(elctAmount);
        IUniswapRouter(PROTOFI_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            IERC20Upgradeable(PROTO).balanceOf(address(this)),
            0,
            protoToWftmRoute,
            address(this),
            block.timestamp
        );

        IERC20Upgradeable wftm = IERC20Upgradeable(WFTM);
        uint256 treasuryFeeToVault = wftm.balanceOf(address(this));
        uint256 feeToStrategist = (treasuryFeeToVault * strategistFee) / PERCENT_DIVISOR;
        treasuryFeeToVault -= feeToStrategist;

        wftm.safeTransfer(treasury, treasuryFeeToVault);
        wftm.safeTransfer(strategistRemitter, feeToStrategist);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the ProtoFi MasterChef, leaving rewards behind.
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
     * @dev Gives the necessary allowances
     */
    function _giveAllowances() internal {
        uint256 wantAllowance = type(uint256).max - IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF);
        IERC20Upgradeable(want).safeIncreaseAllowance(MASTER_CHEF, wantAllowance);

        uint256 electronAllowance = type(uint256).max - IERC20Upgradeable(ELCT).allowance(address(this), moneyPotAddr);
        IERC20Upgradeable(ELCT).safeIncreaseAllowance(moneyPotAddr, electronAllowance);

        uint256 wftmAllowance = type(uint256).max - IERC20Upgradeable(WFTM).allowance(address(this), ZAP);
        IERC20Upgradeable(WFTM).safeIncreaseAllowance(ZAP, wftmAllowance);

        IERC20Upgradeable rewardToken = IERC20Upgradeable(rewardToWftmRoute[0]);
        uint256 rewardAllowance = type(uint256).max - rewardToken.allowance(address(this), PROTOFI_ROUTER);
        rewardToken.safeIncreaseAllowance(PROTOFI_ROUTER, rewardAllowance);
    }

    /**
     * @dev Removes all allowance that were given
     */
    function _removeAllowances() internal {
        IERC20Upgradeable(want).safeDecreaseAllowance(
            MASTER_CHEF,
            IERC20Upgradeable(want).allowance(address(this), MASTER_CHEF)
        );
        IERC20Upgradeable(ELCT).safeDecreaseAllowance(
            moneyPotAddr,
            IERC20Upgradeable(ELCT).allowance(address(this), moneyPotAddr)
        );
        IERC20Upgradeable(WFTM).safeDecreaseAllowance(
            PROTOFI_ROUTER,
            IERC20Upgradeable(WFTM).allowance(address(this), PROTOFI_ROUTER)
        );
        IERC20Upgradeable(rewardToWftmRoute[0]).safeDecreaseAllowance(
            PROTOFI_ROUTER,
            IERC20Upgradeable(rewardToWftmRoute[0]).allowance(address(this), PROTOFI_ROUTER)
        );
    }
}
