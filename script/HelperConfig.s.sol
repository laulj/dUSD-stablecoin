// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script, console } from "forge-std/Script.sol";
import { VRFCoordinatorV2_5Mock } from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import { MockV3Aggregator } from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import { ERC20Mock } from "../test/mocks/ERC20Mock.sol";

abstract contract CodeConstants {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /**
     * Mock Values
     */
    uint8 public MOCK_DECIMALS = 8;
    int256 public MOCK_WETH_INITIAL_ANSWER = 1800e8;
    int256 public MOCK_WBTC_INITIAL_ANSWER = 1000e8;

    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11_155_111;
    uint256 public constant LOCAL_CHAIN_ID = 31_337;
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    address public constant WETH_SEPOLIA_ADDRESS = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    address public constant WBTC_SEPOLIA_ADDRESS = 0x92f3B59a79bFf5dc60c0d59eA13a44D082B2bdFC;
    address public constant WETH_SEPOLIA_PRICEFEED_ADDRESS = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address public constant WBTC_SEPOLIA_PRICEFEED_ADDRESS = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant OVERCOLLATERAL_RATIO = 2;
    uint256 public constant MIN_HEALTH_FACTOR = 1;
    uint256 public constant ZERO_DEBT_HEALTH_FACTOR = type(uint256).max;
}

contract HelperConfig is Script, CodeConstants {
    error HelperConfig__InvalidChainId();
    error HelperConfig__PrivateKeyNotInitiatedProperly();

    address[] tokenAddresses;
    address[] priceFeeds;

    struct NetworkConfig {
        uint256 deployerKey;
        address[] tokenAddresses;
        address[] priceFeeds;
    }

    NetworkConfig public localNetworkConfig;
    mapping(uint256 chainId => NetworkConfig) public networkConfigs;

    constructor() {
        networkConfigs[ETH_SEPOLIA_CHAIN_ID] = getSepoliaEthConfig();
        tokenAddresses = new address[](0);
        priceFeeds = new address[](0);
    }

    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (chainId != LOCAL_CHAIN_ID) {
            NetworkConfig memory _config = networkConfigs[chainId];
            if (_config.deployerKey == 0) revert HelperConfig__PrivateKeyNotInitiatedProperly();

            return _config;
        } else if (chainId == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilEthConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getConfig() public returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    function getSepoliaEthConfig() public returns (NetworkConfig memory) {
        tokenAddresses.push(WETH_SEPOLIA_ADDRESS);
        tokenAddresses.push(WBTC_SEPOLIA_ADDRESS);

        priceFeeds.push(WETH_SEPOLIA_PRICEFEED_ADDRESS);
        priceFeeds.push(WBTC_SEPOLIA_PRICEFEED_ADDRESS);
        uint256 sepoliPrivKey = 0;
        try vm.envUint("PRIVATE_KEY") { }
        catch {
            console.log("Missing sepolia priv key.");
        }

        return NetworkConfig({ deployerKey: sepoliPrivKey, tokenAddresses: tokenAddresses, priceFeeds: priceFeeds });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (localNetworkConfig.tokenAddresses.length != 0) {
            return localNetworkConfig;
        }

        // Deploy mocks
        vm.startBroadcast();
        MockV3Aggregator mockWETHV3Aggregator = new MockV3Aggregator(MOCK_DECIMALS, MOCK_WETH_INITIAL_ANSWER);
        MockV3Aggregator mockWBTCV3Aggregator = new MockV3Aggregator(10, MOCK_WBTC_INITIAL_ANSWER);
        ERC20Mock MockWETH_Token = new ERC20Mock("Wrapped Ether", "WETH", msg.sender, 1000e8);
        ERC20Mock MockWBTC_Token = new ERC20Mock("Wrapped Bitcoin", "WBTC", msg.sender, 1000e8);
        vm.stopBroadcast();

        tokenAddresses.push(address(MockWETH_Token));
        tokenAddresses.push(address(MockWBTC_Token));

        priceFeeds.push(address(mockWETHV3Aggregator));
        priceFeeds.push(address(mockWBTCV3Aggregator));
        localNetworkConfig = NetworkConfig({
            deployerKey: DEFAULT_ANVIL_PRIVATE_KEY, tokenAddresses: tokenAddresses, priceFeeds: priceFeeds
        });

        return localNetworkConfig;
    }
}
