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
        amountCollateral = bound(amountCollateral, 0, MAX_DEPOSIT_AMOUNT);
        address collateralAddr = sanitizeCollateralAddress(collateralSeed);
        ERC20Mock erc20Mock = ERC20Mock(collateralAddr);

        vm.startPrank(msg.sender);
        erc20Mock.mint(msg.sender, amountCollateral);
        erc20Mock.approve(address(dUSDEngine), amountCollateral);
        dUSDEngine.depositCollateral(address(erc20Mock), amountCollateral);
        vm.stopPrank();
    }

    function mintDUSD(uint256 mintAmount) public {
        mintAmount = bound(mintAmount, 0, MAX_DEPOSIT_AMOUNT);

        dUSDEngine.mintDUSD(mintAmount);
        noOfTimesMintIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        address collateralAddr = sanitizeCollateralAddress(collateralSeed);
        ERC20Mock erc20Mock = ERC20Mock(collateralAddr);
        collateralAmount = bound(collateralAmount, 0, MAX_DEPOSIT_AMOUNT);

        erc20Mock.mint(msg.sender, collateralAmount);
        vm.startPrank(msg.sender);
        erc20Mock.approve(address(dUSDEngine), collateralAmount);
        dUSDEngine.depositCollateral(collateralAddr, collateralAmount);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        address collateralAddr = sanitizeCollateralAddress(collateralSeed);
        collateralAmount = bound(collateralAmount, 0, MAX_DEPOSIT_AMOUNT);
        dUSDEngine.redeemCollateral(collateralAddr, collateralAmount);
    }

    function liquidate(address userToBeLiquidated, uint256 debtToCover) public {
        uint256 healthBefore = dUSDEngine.getHealthFactor(userToBeLiquidated);

        debtToCover = bound(debtToCover, 0, MAX_DEPOSIT_AMOUNT);

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

    function liquidateByAsset(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        address collateralAddr = sanitizeCollateralAddress(collateralSeed);
        debtToCover = bound(debtToCover, 0, MAX_DEPOSIT_AMOUNT);

        uint256 healthBefore = dUSDEngine.getHealthFactor(userToBeLiquidated);

        vm.prank(address(dUSDEngine));
        ERC20Mock(address(dUSD)).mint(msg.sender, debtToCover);
        vm.startPrank(msg.sender);
        ERC20Mock(address(dUSD)).approve(address(dUSDEngine), debtToCover);
        dUSDEngine.liquidateByAsset(collateralAddr, userToBeLiquidated, debtToCover);

        if (healthBefore >= dUSDEngine.getMinHealthFactor()) {
            liquidationFailedInvariant = true;
        }
        vm.stopPrank();
        noOfTimesLiquidateByAssetIsCalled++;
    }

    function updateCollateralPrice(
        uint96 percentChangeSeed,
        uint256 priceChangeDirectionSeed,
        uint256 tokenPriceFeedAddressSeed
    )
        public
    {
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
        // if (checkIfPriceChangePutsTheContractInBadDebt(tokenAddress, priceDirection, PERCENT_CHANGE)) return;

        MockV3Aggregator(priceFeedAddress).updateAnswer(int256(uint256(nextPrice)));
    }

    // function checkIfPriceChangePutsTheContractInBadDebt(address tokenAddr, uint256 direction, uint256 changePercent)
    //     public
    //     view
    //     returns (bool)
    // {
    //     uint256 totalSupply = dUSD.totalSupply();
    //     uint256 totalWETHDeposited = WETH.balanceOf(address(dUSDEngine));
    //     uint256 totalWBTCDeposited = WBTC.balanceOf(address(dUSDEngine));
    //     uint256 totalWETHValueInUSD = dUSDEngine._getUSDValue(address(WETH), totalWETHDeposited);
    //     uint256 totalWBTCValueInUSD = dUSDEngine._getUSDValue(address(WBTC), totalWBTCDeposited);
    //     if (tokenAddr == address(WETH)) {
    //         if (direction == 0) {
    //             totalWETHValueInUSD *= (PRICE_PRECISION + changePercent) / PRICE_PRECISION;
    //         } else {
    //             totalWETHValueInUSD *= (PRICE_PRECISION - changePercent) / PRICE_PRECISION;
    //         }
    //     } else if (tokenAddr == address(WBTC)) {
    //         if (direction == 0) {
    //             totalWBTCValueInUSD *= (PRICE_PRECISION + changePercent) / PRICE_PRECISION;
    //         } else {
    //             totalWBTCValueInUSD *= (PRICE_PRECISION - changePercent) / PRICE_PRECISION;
    //         }
    //     }
    //     uint256 totalValueInUSD = totalWETHValueInUSD + totalWBTCValueInUSD;

    //     if (totalSupply <= totalValueInUSD) return false;
    //     return true;
    // }

    /*//////////////////////////////////////////////////////////////
                            DUSD STABLECOIN
    //////////////////////////////////////////////////////////////*/
    function transferDsc(uint256 amountDsc, address to) public {
        amountDsc = bound(amountDsc, 0, dUSD.balanceOf(msg.sender));
        vm.prank(msg.sender);
        dUSD.transfer(to, amountDsc);
    }

    function burnDsc(uint256 amountDsc) public {
        amountDsc = bound(amountDsc, 0, dUSD.balanceOf(msg.sender));
        dUSD.burn(amountDsc);
    }

    function mintDsc(uint256 amountDsc) public {
        amountDsc = bound(amountDsc, 0, MAX_DEPOSIT_AMOUNT);
        dUSD.mint(msg.sender, amountDsc);
    }

    function sanitizeCollateralPriceFeedsAddress(uint256 priceFeedSeed) internal view returns (address) {
        return priceFeeds[priceFeedSeed % 2];
    }

    function sanitizeCollateralAddress(uint256 collateralSeed) internal view returns (address) {
        return tokenAddresses[collateralSeed % 2];
    }
}
