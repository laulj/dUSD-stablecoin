// SPDX-License-Identifier: MIT
/*
    Invariants
    1. The total supply of DUSD should be less than the total value collateralized,
    2. Getter function should never revert <- evergreen invariant.
*/
pragma solidity ^0.8.19;

import { Test, console } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { DUSD } from "../../../src/DUSDStableCoin.sol";
import { DUSDEngine } from "../../../src/DUSDEngine.sol";
import { DUSDScript } from "../../../script/DeployDUSD.s.sol";
import { HelperConfig } from "../../../script/HelperConfig.s.sol";
import { ERC20Mock } from "../../../test/mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../../../test/mocks/MockV3Aggregator.sol";

contract InvariantsHandler is Test {
    DUSD dUSD;
    DUSDEngine dUSDEngine;
    address[] public tokenAddresses;
    address[] public priceFeeds;
    address[] public usersWithCollateralDeposited;
    address[] public userWithDebt;
    ERC20Mock WETH;
    ERC20Mock WBTC;
    MockV3Aggregator WETH_PriceFeed;
    MockV3Aggregator WBTC_PriceFeed;

    // Ghost Variables
    uint256 public noOfTimesMintIsCalled = 0;
    uint256 public noOfTimesLiquidateByAssetIsCalled = 0;
    uint256 public noOfTimesLiquidateIsCalled = 0;
    bool public liquidationFailedInvariant = false;

    uint96 constant MAX_DEPOSIT_AMOUNT = type(uint96).max;
    uint256 constant MIN_DEPOSIT_AMOUNT = 1e5;
    uint256 constant MIN_PRICE_CHANGE_PERCENT = 5;
    uint256 constant MAX_PRICE_CHANGE_PERCENT = 30;
    uint256 constant PRICE_PRECISION = 100;

    constructor(DUSD _dUSD, DUSDEngine _dUSDEngine) {
        dUSD = _dUSD;
        dUSDEngine = _dUSDEngine;

        address[] memory tokenAddr = dUSDEngine.getCollateralTokens();
        tokenAddresses = tokenAddr;
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            priceFeeds.push(dUSDEngine.getCollateralTokenPriceFeed(tokenAddresses[i]));
        }
        WETH = ERC20Mock(tokenAddr[0]);
        WBTC = ERC20Mock(tokenAddr[1]);

        WETH_PriceFeed = MockV3Aggregator(priceFeeds[0]);
        WBTC_PriceFeed = MockV3Aggregator(priceFeeds[1]);
    }

    /*//////////////////////////////////////////////////////////////
                               DUSDENGINE
    //////////////////////////////////////////////////////////////*/
    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        amountCollateral = bound(amountCollateral, MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);
        address collateralAddr = sanitizeCollateralAddress(collateralSeed);
        ERC20Mock erc20Mock = ERC20Mock(collateralAddr);

        vm.startPrank(msg.sender);
        erc20Mock.mint(msg.sender, amountCollateral);
        erc20Mock.approve(address(dUSDEngine), amountCollateral);
        dUSDEngine.depositCollateral(address(erc20Mock), amountCollateral);
        vm.stopPrank();
    }

    function mintDUSD(uint256 mintAmount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address msgSender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        vm.startPrank(msgSender);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

        uint256 maxMintableDUSDAmount = totalCollateralValue / dUSDEngine.getOvercollateralRatio();
        uint256 maxAvailableToMintDUSD = 0;

        // Skip undercollateral revert cases
        if (maxMintableDUSDAmount <= totalDUSDMinted) {
            vm.stopPrank();
            return;
        } else {
            maxAvailableToMintDUSD = maxMintableDUSDAmount - totalDUSDMinted;
        }

        mintAmount = bound(mintAmount, 0, maxAvailableToMintDUSD);

        // Will revert if minting zero amount or user hasn't deposited any collateral
        if (mintAmount == 0 || totalCollateralValue == 0) {
            vm.stopPrank();
            return;
        }

        dUSDEngine.mintDUSD(mintAmount);
        noOfTimesMintIsCalled++;
        vm.stopPrank();

        for (uint256 i = 0; i < userWithDebt.length; i++) {
            if (userWithDebt[i] == msgSender) return;
        }
        userWithDebt.push(msgSender);
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        address collateralAddr = sanitizeCollateralAddress(collateralSeed);
        ERC20Mock erc20Mock = ERC20Mock(collateralAddr);
        collateralAmount = bound(collateralAmount, MIN_DEPOSIT_AMOUNT, MAX_DEPOSIT_AMOUNT);

        vm.startPrank(msg.sender);
        erc20Mock.mint(msg.sender, collateralAmount);
        erc20Mock.approve(address(dUSDEngine), collateralAmount);
        dUSDEngine.depositCollateral(collateralAddr, collateralAmount);
        vm.stopPrank();

        for (uint256 i = 0; i < usersWithCollateralDeposited.length; i++) {
            if (usersWithCollateralDeposited[i] == msg.sender) return;
        }
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        address collateralAddr = sanitizeCollateralAddress(collateralSeed);

        vm.startPrank(msg.sender);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

        // Overcollateral ratio * mintedDUSD = required collateral to stay healthy
        uint256 unRedeemableCollateralValue = totalDUSDMinted * dUSDEngine.getOvercollateralRatio();
        uint256 maxRedeemableCollateralValue = 0;

        // Prevent arithmetic underflow
        if (totalCollateralValue <= unRedeemableCollateralValue) {
            vm.stopPrank();
            return;
        } else {
            maxRedeemableCollateralValue = totalCollateralValue - unRedeemableCollateralValue;
        }

        uint256 maxRedeemableCollateralAmount =
            dUSDEngine.getTokenAmountFromUSD(collateralAddr, maxRedeemableCollateralValue);
        uint256 userHas = dUSDEngine.getCollateralDeposited(msg.sender, collateralAddr);
        if (maxRedeemableCollateralAmount > userHas) maxRedeemableCollateralAmount = userHas;

        collateralAmount = bound(collateralAmount, 0, maxRedeemableCollateralAmount);

        if (collateralAmount == 0) {
            vm.stopPrank();
            return;
        } // Will revert if redeeming zero amount

        dUSDEngine.redeemCollateral(collateralAddr, collateralAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/
    function liquidate(uint256 addressSeed, uint256 debtToCover) public {
        if (userWithDebt.length == 0) return;

        address userToBeLiquidated = userWithDebt[addressSeed % userWithDebt.length];
        uint256 healthBefore = dUSDEngine.getHealthFactor(userToBeLiquidated);

        // User totalCollateralValue / totalDebt >= 1 + liquidation bonus for liquidation to be successful
        if (!dUSDEngine.isLiquidable(userToBeLiquidated)) return;

        uint256 userMaxDebt = dUSDEngine.getMaxDebtToCover(userToBeLiquidated);

        vm.prank(userToBeLiquidated);
        (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

        uint256 totalCollateralValueLeft = totalCollateralValue - userMaxDebt
            * (dUSDEngine.getLiquidationPrecision() + dUSDEngine.getLiquidationBonus())
            / dUSDEngine.getLiquidationPrecision();
        uint256 expectedNewHealthFactorIfRepaidAllDebt =
            dUSDEngine.calculateHealthFactor(totalDUSDMinted - userMaxDebt, totalCollateralValueLeft);

        // Skip liquidation that does not bring healthfactor back to minHealthFactor
        if (expectedNewHealthFactorIfRepaidAllDebt < dUSDEngine.getMinHealthFactor()) return;

        uint256 minDebtToRepayBringHealthFactorBackToMinHealthFactor = totalDUSDMinted - dUSDEngine.getMinHealthFactor()
            * totalCollateralValueLeft / (dUSDEngine.getOvercollateralRatio() * dUSDEngine.getPrecision());

        debtToCover = bound(debtToCover, minDebtToRepayBringHealthFactorBackToMinHealthFactor, userMaxDebt);

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(msg.sender, debtToCover);
        vm.startPrank(msg.sender);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), debtToCover);
        dUSDEngine.liquidate(userToBeLiquidated, debtToCover);
        if (healthBefore >= dUSDEngine.getMinHealthFactor()) {
            liquidationFailedInvariant = true;
        }
        vm.stopPrank();
        noOfTimesLiquidateIsCalled++;
    }

    function liquidateByAsset(uint256 addressSeed, uint256 debtToCover) public {
        if (userWithDebt.length == 0) return;

        address userToBeLiquidated = userWithDebt[addressSeed % userWithDebt.length];
        uint256 healthBefore = dUSDEngine.getHealthFactor(userToBeLiquidated);

        // User totalCollateralValue / totalDebt >= 1 + liquidation bonus for liquidation to be successful
        if (!dUSDEngine.isLiquidable(userToBeLiquidated)) return;

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            if (dUSDEngine.getCollateralDeposited(userToBeLiquidated, tokenAddresses[i]) == 0) continue;

            uint256 userMaxDebt =
                dUSDEngine.getMaxDebtToCoverForSpecificCollateral(userToBeLiquidated, tokenAddresses[i]);

            vm.prank(userToBeLiquidated);
            (uint256 totalDUSDMinted, uint256 totalCollateralValue) = dUSDEngine.getAccountInfo();

            uint256 totalCollateralValueLeft = totalCollateralValue - userMaxDebt
                * (dUSDEngine.getLiquidationPrecision() + dUSDEngine.getLiquidationBonus())
                / dUSDEngine.getLiquidationPrecision();
            uint256 expectedNewHealthFactorIfRepaidAllDebt =
                dUSDEngine.calculateHealthFactor(totalDUSDMinted - userMaxDebt, totalCollateralValueLeft);

            // Skip liquidation that does not bring healthfactor back to minHealthFactor
            if (expectedNewHealthFactorIfRepaidAllDebt < dUSDEngine.getMinHealthFactor()) continue;

            // MIN_HEALTH_FACTOR  =  (totalDUSDMinted - x ) * dUSDEngine.getOvercollateralRatio() /
            // totalCollateralValueLeft
            // totalDUSDMinted - x = MIN_HEALTH_FACTOR * totalCollateralValueLeft / dUSDEngine.getOvercollateralRatio()
            //                   x = totalDUSDMinted - MIN_HEALTH_FACTOR * totalCollateralValueLeft /
            // dUSDEngine.getOvercollateralRatio()
            uint256 minDebtToRepayBringHealthFactorBackToMinHealthFactor = totalDUSDMinted
                - dUSDEngine.getMinHealthFactor() * totalCollateralValueLeft
                / (dUSDEngine.getOvercollateralRatio() * dUSDEngine.getPrecision());

            debtToCover = bound(debtToCover, minDebtToRepayBringHealthFactorBackToMinHealthFactor, userMaxDebt);

            vm.prank(address(dUSDEngine));
            ERC20Mock(address(dUSD)).mint(msg.sender, debtToCover);
            vm.startPrank(msg.sender);
            ERC20Mock(address(dUSD)).approve(address(dUSDEngine), debtToCover);
            dUSDEngine.liquidateByAsset(tokenAddresses[i], userToBeLiquidated, debtToCover);
            if (healthBefore >= dUSDEngine.getMinHealthFactor()) {
                liquidationFailedInvariant = true;
            }
            vm.stopPrank();
            noOfTimesLiquidateByAssetIsCalled++;
            break;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 PRICE
    //////////////////////////////////////////////////////////////*/
    function updateCollateralPrice(
        uint96 percentChangeSeed,
        uint256 priceChangeDirectionSeed,
        uint256 tokenPriceFeedAddressSeed
    )
        public
    {
        if (userWithDebt.length == 0) return;

        address priceFeedAddress = sanitizeCollateralPriceFeedsAddress(tokenPriceFeedAddressSeed);
        (, int256 currentPrice,,,) = MockV3Aggregator(priceFeedAddress).latestRoundData();
        uint256 priceDirection = priceChangeDirectionSeed % 2;
        uint96 PERCENT_CHANGE = uint96(bound(percentChangeSeed, MIN_PRICE_CHANGE_PERCENT, MAX_PRICE_CHANGE_PERCENT));

        uint256 nextPrice = uint256(currentPrice) * (PRICE_PRECISION - PERCENT_CHANGE) / PRICE_PRECISION;
        if (priceDirection == 0) {
            nextPrice = uint256(currentPrice) * (PRICE_PRECISION + PERCENT_CHANGE) / PRICE_PRECISION;
        }

        address tokenAddress = address(WETH);
        if (priceFeedAddress == address(WBTC_PriceFeed)) tokenAddress = address(WBTC);

        // Test for cases where price changes but not put the contract into undercollaterized position
        if (checkIfPriceChangePutsTheContractInBadDebt(tokenAddress, priceDirection, PERCENT_CHANGE)) {
            return;
        }

        MockV3Aggregator(priceFeedAddress).updateAnswer(int256(uint256(nextPrice)));
    }

    function checkIfPriceChangePutsTheContractInBadDebt(
        address tokenAddr,
        uint256 direction,
        uint256 changePercent
    )
        public
        view
        returns (bool)
    {
        uint256 totalSupply = dUSD.totalSupply();
        uint256 totalWETHDeposited = WETH.balanceOf(address(dUSDEngine));
        uint256 totalWBTCDeposited = WBTC.balanceOf(address(dUSDEngine));
        uint256 totalWETHValueInUSD = dUSDEngine._getUSDValue(address(WETH), totalWETHDeposited);
        uint256 totalWBTCValueInUSD = dUSDEngine._getUSDValue(address(WBTC), totalWBTCDeposited);
        if (tokenAddr == address(WETH)) {
            if (direction == 0) {
                totalWETHValueInUSD *= (PRICE_PRECISION + changePercent) / PRICE_PRECISION;
            } else {
                totalWETHValueInUSD *= (PRICE_PRECISION - changePercent) / PRICE_PRECISION;
            }
        } else if (tokenAddr == address(WBTC)) {
            if (direction == 0) {
                totalWBTCValueInUSD *= (PRICE_PRECISION + changePercent) / PRICE_PRECISION;
            } else {
                totalWBTCValueInUSD *= (PRICE_PRECISION - changePercent) / PRICE_PRECISION;
            }
        }
        uint256 totalValueInUSD = totalWETHValueInUSD + totalWBTCValueInUSD;

        if (totalSupply <= totalValueInUSD) return false;
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            DUSD STABLECOIN
    //////////////////////////////////////////////////////////////*/
    function transferDsc(uint256 amountDsc, address to) public {
        if (to == address(0)) {
            to = address(1);
        }
        amountDsc = bound(amountDsc, 0, dUSD.balanceOf(msg.sender));
        vm.prank(msg.sender);
        dUSD.transfer(to, amountDsc);
    }

    /*//////////////////////////////////////////////////////////////
                             UTIL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function sanitizeCollateralPriceFeedsAddress(uint256 priceFeedSeed) internal view returns (address) {
        return priceFeeds[priceFeedSeed % 2];
    }

    function sanitizeCollateralAddress(uint256 collateralSeed) internal view returns (address) {
        return tokenAddresses[collateralSeed % 2];
    }
}
