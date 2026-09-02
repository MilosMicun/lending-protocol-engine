// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {SepoliaDemoERC20} from "../src/demo/SepoliaDemoERC20.sol";

/// @dev Read-only surface of the externally managed Chainlink ETH/USD proxy.
interface IChainlinkEthUsdFeed {
    function description() external view returns (string memory);

    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Preflights and, when explicitly invoked with --broadcast, deploys educational Sepolia demo dependencies.
/// @dev This script never deploys or mutates a price feed and never interacts with LendingPool.
contract DeploySepoliaDemoDependencies is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant WAD = 1e18;
    uint8 public constant EXPECTED_FEED_DECIMALS = 8;
    string public constant EXPECTED_FEED_DESCRIPTION = "ETH / USD";

    struct DeploymentConfig {
        address holder;
        uint256 collateralInitialSupply;
        uint256 debtInitialSupply;
        address priceFeed;
        uint256 maxPriceStaleness;
        uint256 expectedChainId;
    }

    struct FeedRoundData {
        uint80 roundId;
        int256 answer;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    error InvalidExpectedChainId(uint256 configuredChainId);
    error UnexpectedChainId(uint256 expectedChainId, uint256 actualChainId);
    error InvalidDemoTokenHolder(address holder);
    error InvalidCollateralInitialSupply(uint256 supply);
    error InvalidDebtInitialSupply(uint256 supply);
    error InvalidPriceFeed(address priceFeed);
    error InvalidMaxPriceStaleness(uint256 maxPriceStaleness);
    error PriceFeedHasNoCode(address priceFeed);
    error UnexpectedFeedDescription(string actualDescription);
    error UnexpectedFeedDecimals(uint8 actualDecimals);
    error NonPositivePrice(int256 answer);
    error ZeroPriceTimestamp();
    error FuturePriceTimestamp(uint256 updatedAt, uint256 currentTimestamp);
    error StalePrice(uint256 updatedAt, uint256 currentTimestamp, uint256 maxPriceStaleness);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);
    error DeploymentVerificationFailed(bytes32 field);

    function run() external returns (SepoliaDemoERC20 collateralToken, SepoliaDemoERC20 debtToken) {
        DeploymentConfig memory config = _readDeploymentConfig();
        FeedRoundData memory feedData = validateConfig(config);

        vm.startBroadcast();
        (collateralToken, debtToken) = _deploy(config);
        vm.stopBroadcast();

        validateDeployment(config, collateralToken, debtToken);
        _logDeployment(config, collateralToken, debtToken, feedData);
    }

    /// @notice Local, non-broadcast deployment entry point used by script tests.
    function deploy(DeploymentConfig memory config)
        public
        returns (SepoliaDemoERC20 collateralToken, SepoliaDemoERC20 debtToken)
    {
        validateConfig(config);
        (collateralToken, debtToken) = _deploy(config);
        validateDeployment(config, collateralToken, debtToken);
    }

    function validateConfig(DeploymentConfig memory config) public view returns (FeedRoundData memory feedData) {
        if (config.expectedChainId != SEPOLIA_CHAIN_ID) {
            revert InvalidExpectedChainId(config.expectedChainId);
        }
        if (block.chainid != SEPOLIA_CHAIN_ID) {
            revert UnexpectedChainId(SEPOLIA_CHAIN_ID, block.chainid);
        }
        if (config.holder == address(0)) revert InvalidDemoTokenHolder(config.holder);
        if (config.collateralInitialSupply == 0) {
            revert InvalidCollateralInitialSupply(config.collateralInitialSupply);
        }
        if (config.debtInitialSupply == 0) revert InvalidDebtInitialSupply(config.debtInitialSupply);
        if (config.priceFeed == address(0)) revert InvalidPriceFeed(config.priceFeed);
        if (config.maxPriceStaleness == 0) revert InvalidMaxPriceStaleness(config.maxPriceStaleness);
        if (config.priceFeed.code.length == 0) revert PriceFeedHasNoCode(config.priceFeed);

        IChainlinkEthUsdFeed feed = IChainlinkEthUsdFeed(config.priceFeed);
        string memory description = feed.description();
        if (keccak256(bytes(description)) != keccak256(bytes(EXPECTED_FEED_DESCRIPTION))) {
            revert UnexpectedFeedDescription(description);
        }
        uint8 feedDecimals = feed.decimals();
        if (feedDecimals != EXPECTED_FEED_DECIMALS) revert UnexpectedFeedDecimals(feedDecimals);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert NonPositivePrice(answer);
        if (updatedAt == 0) revert ZeroPriceTimestamp();
        if (updatedAt > block.timestamp) revert FuturePriceTimestamp(updatedAt, block.timestamp);
        if (block.timestamp - updatedAt > config.maxPriceStaleness) {
            revert StalePrice(updatedAt, block.timestamp, config.maxPriceStaleness);
        }
        if (answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);

        feedData =
            FeedRoundData({roundId: roundId, answer: answer, updatedAt: updatedAt, answeredInRound: answeredInRound});
    }

    function validateDeployment(
        DeploymentConfig memory config,
        SepoliaDemoERC20 collateralToken,
        SepoliaDemoERC20 debtToken
    ) public view {
        _validateToken(
            collateralToken,
            "Sepolia Demo Ether",
            "sdETH",
            config.holder,
            config.collateralInitialSupply,
            "collateralToken"
        );
        _validateToken(debtToken, "Sepolia Demo USD", "sdUSD", config.holder, config.debtInitialSupply, "debtToken");
        validateConfig(config);
    }

    function normalizedEthUsdPriceWad(int256 answer, uint8 feedDecimals) public pure returns (uint256) {
        if (answer <= 0) revert NonPositivePrice(answer);
        return SafeCast.toUint256(answer) * WAD / 10 ** feedDecimals;
    }

    function collateralRawToDebtRaw(uint256 collateralRaw, uint256 priceWad) public pure returns (uint256) {
        return collateralRaw * priceWad / WAD;
    }

    function _deploy(DeploymentConfig memory config)
        internal
        returns (SepoliaDemoERC20 collateralToken, SepoliaDemoERC20 debtToken)
    {
        collateralToken =
            new SepoliaDemoERC20("Sepolia Demo Ether", "sdETH", config.holder, config.collateralInitialSupply);
        debtToken = new SepoliaDemoERC20("Sepolia Demo USD", "sdUSD", config.holder, config.debtInitialSupply);
    }

    function _readDeploymentConfig() internal view returns (DeploymentConfig memory config) {
        config = DeploymentConfig({
            holder: vm.envAddress("DEMO_TOKEN_HOLDER"),
            collateralInitialSupply: vm.envUint("COLLATERAL_INITIAL_SUPPLY"),
            debtInitialSupply: vm.envUint("DEBT_INITIAL_SUPPLY"),
            priceFeed: vm.envAddress("PRICE_FEED"),
            maxPriceStaleness: vm.envUint("MAX_PRICE_STALENESS"),
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID")
        });
    }

    function _validateToken(
        SepoliaDemoERC20 token,
        string memory expectedName,
        string memory expectedSymbol,
        address expectedHolder,
        uint256 expectedSupply,
        bytes32 field
    ) internal view {
        if (address(token).code.length == 0) revert DeploymentVerificationFailed(field);
        if (keccak256(bytes(token.name())) != keccak256(bytes(expectedName))) {
            revert DeploymentVerificationFailed(field);
        }
        if (keccak256(bytes(token.symbol())) != keccak256(bytes(expectedSymbol))) {
            revert DeploymentVerificationFailed(field);
        }
        if (
            token.decimals() != 18 || token.totalSupply() != expectedSupply
                || token.balanceOf(expectedHolder) != expectedSupply
        ) {
            revert DeploymentVerificationFailed(field);
        }
    }

    function _logDeployment(
        DeploymentConfig memory config,
        SepoliaDemoERC20 collateralToken,
        SepoliaDemoERC20 debtToken,
        FeedRoundData memory feedData
    ) internal view {
        uint256 priceWad = normalizedEthUsdPriceWad(feedData.answer, EXPECTED_FEED_DECIMALS);
        uint256 debtRawForOneCollateral = collateralRawToDebtRaw(10 ** collateralToken.decimals(), priceWad);

        console2.log("Sepolia demo collateral token:", address(collateralToken));
        console2.log("  runtime code present:", address(collateralToken).code.length > 0);
        console2.log("  name:", collateralToken.name());
        console2.log("  symbol:", collateralToken.symbol());
        console2.log("  decimals:", collateralToken.decimals());
        console2.log("  total supply:", collateralToken.totalSupply());
        console2.log("  holder balance:", collateralToken.balanceOf(config.holder));
        console2.log("Sepolia demo debt token:", address(debtToken));
        console2.log("  runtime code present:", address(debtToken).code.length > 0);
        console2.log("  name:", debtToken.name());
        console2.log("  symbol:", debtToken.symbol());
        console2.log("  decimals:", debtToken.decimals());
        console2.log("  total supply:", debtToken.totalSupply());
        console2.log("  holder balance:", debtToken.balanceOf(config.holder));
        console2.log("ETH/USD feed:", config.priceFeed);
        console2.log("  description:", EXPECTED_FEED_DESCRIPTION);
        console2.log("  decimals:", EXPECTED_FEED_DECIMALS);
        console2.log("  round ID:", uint256(feedData.roundId));
        console2.log("  answer:", uint256(feedData.answer));
        console2.log("  updatedAt:", feedData.updatedAt);
        console2.log("  normalized ETH/USD WAD:", priceWad);
        console2.log("  1e18 sdETH raw -> sdUSD raw:", debtRawForOneCollateral);
    }
}
