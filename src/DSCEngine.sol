// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DecentralizedStablecoin} from "./DecentralizedStablecoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Mayank Chhipa
 * @notice This contract is an core of Decentralized Stablecoin(DSC) system. It handles the mining and
 * redeeming of DSC token, as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on MakerDAO DSS(DAI Stablecoin System) (DAI) system.
 *
 * The system is designed to be as minimal as possible and have the value of DSC token
 * as 1 DSC == 1$.
 * This stablecoin has following properties:
 * - Exogneous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees and was only
 * backed by WETH and WBTC.
 *
 * The DSC system is always "overcollateralized". At no point, should the value of all collateral be <= the
 * $ backed value of all DSC.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////////
    // State Variables //
    ////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; //10%
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    mapping(address token => address priceFeed) private s_priceFeed;
    DecentralizedStablecoin private immutable i_dsc;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    ////////////////
    // Events     //
    ////////////////
    event CollateralDeposited(address indexed user, address indexed collateralTokenAddress, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed collateralTokenAddress, uint256 amount
    );

    ////////////////
    // Errors     //
    ////////////////
    error DSCEngine__AmountIsZero();
    error DSCEngine__MismatchBetweenLengthOfTokenAddressAndPriceFeedAddress();
    error DSCEngine__IsNotAllowedCollateralToken();
    error DSCEngine__CollateralDepositFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__CollateralRedemptionFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSC_Engine__HealthFactorNotImproved();

    ////////////////
    // Modifiers  //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__AmountIsZero();
        }
        _;
    }

    modifier onlyAllowedCollateralToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__IsNotAllowedCollateralToken();
        }
        _;
    }

    ////////////////
    // Functions  //
    ///////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // USD price Feeds ex: USD/ETH, USD/BTC, MKR/USD etc.
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__MismatchBetweenLengthOfTokenAddressAndPriceFeedAddress();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_collateralTokens.push(tokenAddresses[i]);
            s_priceFeed[tokenAddresses[i]] = priceFeedAddress[i];
        }
        i_dsc = DecentralizedStablecoin(dscAddress);
    }

    /////////////////////////
    // External Functions  //
    ////////////////////////

    /**
     * @param collateralTokenAddress Token address of the collateral to be deposited
     * @param collateralAmount Amount of collateral token to be deposited
     * @param mintAmount Amount of DSC tokens to be minted
     * @notice this function will deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(address collateralTokenAddress, uint256 collateralAmount, uint256 mintAmount)
        external
    {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDSC(mintAmount);
    }

    /**
     * @notice Follows CEI Pattern(Checks, Effects, Interactions)
     * @param collateralTokenAddress The address of the token to deposit as collateral in wei
     * @param collateralAmount The amount of collateral to deposit
     */
    function depositCollateral(address collateralTokenAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        onlyAllowedCollateralToken(collateralTokenAddress)
        nonReentrant
    {
        // effects
        s_collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);

        //interactions
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__CollateralDepositFailed();
        }
    }

    /**
     * @param collateralTokenAddress collateral token to redeem
     * @param collateralAmount collateral amount to redeem
     * @param dscAmount DSC amount to deposit and burn
     * @notice this function redeems collateral and burns DSC in single transaction
     */
    function redeemCollateralForDSC(address collateralTokenAddress, uint256 collateralAmount, uint256 dscAmount)
        external
        onlyAllowedCollateralToken(collateralTokenAddress)
        nonReentrant
    {
        burnDSC(dscAmount);
        redeemCollateral(collateralTokenAddress, collateralAmount);
        // redeem collateral already checks health factor
    }

    /**
     * @param collateralTokenAddress address of collateral token to redeem
     * @param amount amount of collateral  token to redeem
     * @notice this function performs redemption of deposited collateral token to the user
     */
    function redeemCollateral(address collateralTokenAddress, uint256 amount)
        public
        moreThanZero(amount)
        nonReentrant
    {
        _redeemCollateral(collateralTokenAddress, amount, msg.sender, msg.sender);
    }

    /**
     * @notice follows CEI pattern
     * @param amount The amount of DSC to mint
     * @notice They must have more collateral value than the minimum threshold for amount to mint
     */
    function mintDSC(uint256 amount) public moreThanZero(amount) nonReentrant {
        //Effect - make state consistent
        s_dscMinted[msg.sender] += amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_dsc.mint(msg.sender, amount);
        if (!success) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender); // this might not be needed
    }

    /**
     * @param collateral collateral token address to liquidate
     * @param user user whose health factor is broken i.e. < MIN_HEALTH_FACTOR
     * @param debtToCover debt amount that will be paid by the liquidator and burnt by the system
     * @notice You can partially liquidate a user
     * @notice Liquidator gets a bonus amount for the service
     * @notice This function works given that we assume the debt will be overcollateralized 200% to fund bonus amount
     * @notice A known bug would be if the protocol gets undercollateralized i.e. < 100%, then there would be
     * disincentive for liquidator
     * @notice For example, if the value of collateral falls below the value of debt for that user
     * @notice Debt to cover should be less than or equal to total debt
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //checks
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtToCover = getTokenAmountFromUSD(collateral, debtToCover);
        // Give liquidator 10% bonus
        // so we are giving liquidator $110 of WETH for 100 DSC
        // we should implement a feature to liquidate protocol in case of insolvency
        // and sweep extra amounts in treasury
        uint256 bonusCollateral = (tokenAmountFromDebtToCover * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtToCover + bonusCollateral;
        //effects
        // burn dsc
        // redeem collateral to liquidator
        //interactions
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDSC(user, msg.sender, debtToCover);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSC_Engine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalCollateralInUSD, uint256 totalDscMinted)
    {
        return _getAccountInformation(user);
    }

    function getHealthFactor() external view {}

    /////////////////////////
    // Public Functions  //
    ////////////////////////

    function getTokenAmountFromUSD(address token, uint256 usdValueInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        // price is price of 1 token in USD, price is 1e8
        // amount of  token = usdValue / price
        return (usdValueInWei * PRECISION / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        // will be in 8 DECIMALS and amount will be in WEI 18 DECIMALS
        // so first I need to bring price and amount to same decimal precision i.e. 18 DECIMALS
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountCollateralValueInUSD(address user) public view returns (uint256 totalCollateralInUSD) {
        // here you would not want to iterate over a mapping due to higher gas cost
        // instead we add another array of collateral tokens to use as keys
        totalCollateralInUSD = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            totalCollateralInUSD +=
                getUSDValue(s_collateralTokens[i], s_collateralDeposited[user][s_collateralTokens[i]]);
        }
        return totalCollateralInUSD;
    }

    /////////////////////////
    // Internal Functions  //
    ////////////////////////

    /**
     * @dev Low level internal function, do not call unless the function calling it is checking
     * for health factor breaks.
     */
    function _burnDSC(address user, address dscFrom, uint256 amount) private {
        // can't burn more than what he has minted/actually owns
        s_dscMinted[user] -= amount;
        // you cannot either directly burn the tokens but first transfer it yourself and then burn
        bool success = i_dsc.transferFrom(dscFrom, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
    }

    function _redeemCollateral(address collateralTokenAddress, uint256 amount, address user, address to) private {
        // checks: check if health factor will get broken after redemption
        // effects: update state to take in DSC anf give out collateral tokens accordingly
        // what if amount>deposited amount, uint256 protects us
        s_collateralDeposited[user][collateralTokenAddress] -= amount;
        emit CollateralRedeemed(user, to, collateralTokenAddress, amount);
        _revertIfHealthFactorIsBroken(user);

        // interactions: perform collateral transfer
        bool success = IERC20(collateralTokenAddress).transfer(to, amount);
        if (!success) {
            revert DSCEngine__CollateralRedemptionFailed();
        }
    }

    /**
     * @notice Get Total Collateral Value(in USD) and total DSC minted by User
     * @param user User for whom to get account info
     * @return totalCollateralInUSD total value in USD of collateral deposited by user
     * @return totalDscMinted total value(in USD) of DSC minted by user. 1 DSC == 1 USD
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalCollateralInUSD, uint256 totalDscMinted)
    {
        totalDscMinted = s_dscMinted[user];
        totalCollateralInUSD = getAccountCollateralValueInUSD(user);
        return (totalCollateralInUSD, totalDscMinted);
    }

    /**
     * Returns how close a users's collateral is close to liquidation
     * if health factor is == 1, user's collateral can be liquidated
     *
     */
    function _healthFactor(address user) private view returns (uint256) {
        // 1. Get USD value of total collateral deposited by user
        // 2. Get total DSC (in USD) minted by user
        // 3. Compare it to minimum threshold value required to avoid liquidation
        (uint256 totalCollateralInUSD, uint256 totalDscMinted) = _getAccountInformation(user);
        // totalCollateralInUSD / totalDscMinted will not work as decimals don't work in solidity, 1.5==1
        uint256 collateralAdjustedForThreshold = (totalCollateralInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health Factor(Do they have enough collateral left after this mint transaction?)
        // 2. revert if they don't have enough collateral
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}
