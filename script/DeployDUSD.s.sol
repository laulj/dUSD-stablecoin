// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import { DUSD } from "../src/DUSDStableCoin.sol";
import { DUSDEngine } from "../src/DUSDEngine.sol";
import { HelperConfig } from "./HelperConfig.s.sol";

contract DUSDScript is Script {
    address[] public tokenAddresses;
    address[] public priceFeeds;

    function deployContract() public returns (DUSD, DUSDEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory networkConfig = helperConfig.getConfig();

        vm.startBroadcast(networkConfig.deployerKey);

        DUSD dUSD = new DUSD();
        DUSDEngine dUSDEngine = new DUSDEngine(networkConfig.tokenAddresses, networkConfig.priceFeeds, address(dUSD));

        dUSD.transferOwnership(address(dUSDEngine));
        vm.stopBroadcast();

        return (dUSD, dUSDEngine, helperConfig);
    }

    function run() public {
        deployContract();
    }
}
