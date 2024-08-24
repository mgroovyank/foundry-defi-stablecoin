// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStablecoin} from "../../src/DecentralizedStablecoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DecentralizedStablecoin dsc;
    DSCEngine dscEngine;
    address weth;
    address wbtc;
    address wethUSDPriceFeed;
    address wbtcUSDPriceFeed;
    HelperConfig helperConfig;

    uint256 constant AMOUNT_COLLATERAL = 10 ether;
    uint256 constant STARTING_USER_BALANCE = 10 ether;
    uint256 constant DSC_MINT_AMOUNT = 100e18;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address USER = makeAddr("user");

    //name setUp is case-sensitive
    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        /**
         * we have to use same config as the one used to deploy contracts to ensure same mocks are used
         * if we create another config, new mocks with new address will be deployed
         * which will not match with the mock addresses embedded in contracts
         */
        (wethUSDPriceFeed, wbtcUSDPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_USER_BALANCE);
        console.log("Setup finished");
    }

    //////////////////////////
    //// Constructor Tests///
    ////////////////////////

    function testRevertIfTokenLengthDoesNotMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUSDPriceFeed);
        priceFeedAddresses.push(wbtcUSDPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__MismatchBetweenLengthOfTokenAddressAndPriceFeedAddress.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////////////
    //// Price Feed Tests //////////
    //////////////////////////////

    function testGetUSDValue() public view {
        uint256 usdValue = dscEngine.getUSDValue(weth, 1e18);
        // 1 ETH * 2000 USD/ETH = 2000USD
        uint256 expectedUSDValue = 2000e18;
        assertEq(usdValue, expectedUSDValue);
    }

    function testGetTokenAmountFromUSD() public view {
        address token = weth;
        uint256 usdValueInWei = 100e18;
        // 100 / 2000 = 0.05 ETH
        uint256 expectedTokenAmount = 0.05e18;
        uint256 actualTokenAmount = dscEngine.getTokenAmountFromUSD(token, usdValueInWei);
        assertEq(actualTokenAmount, expectedTokenAmount);
    }

    /////////////////////////////////////
    //// Deposit Collateral Tests ///////
    ////////////////////////////////////

    function testRevertIfZeroCollateral() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AmountIsZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfUnapprovedCollateral() public {
        ERC20Mock unapprovedCollateral = new ERC20Mock();
        vm.expectRevert(DSCEngine.DSCEngine__IsNotAllowedCollateralToken.selector);
        dscEngine.depositCollateral(address(unapprovedCollateral), 1);
    }

    // since collateral deposit will be used in multiple tests, we can create a modifier
    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralAndAccountInfo() public collateralDeposited {
        (uint256 totalCollateralInUSD, uint256 totalDscMinted) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
        assertEq(totalCollateralInUSD, dscEngine.getUSDValue(weth, AMOUNT_COLLATERAL));
    }

    function testDepositCollateralAndMintDSC() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, DSC_MINT_AMOUNT);
        vm.stopPrank();
        assertEq(DSC_MINT_AMOUNT, dsc.balanceOf(USER));
    }

    function testRevertHealthFactorBrokenDepositCollateralAndMintDSC() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 5e17));
        // 10 ether * 2000 USD/ETH = 20000 USD
        // 10000 USD - max dsc mint limit
        //  10000/200*100 = 10000/20000 = 0.5
        dscEngine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 200 * DSC_MINT_AMOUNT);
        vm.stopPrank();
    }
}
