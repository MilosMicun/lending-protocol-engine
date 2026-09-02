// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SepoliaDemoERC20} from "../../src/demo/SepoliaDemoERC20.sol";
import {DeploySepoliaDemoDependencies} from "../../script/DeploySepoliaDemoDependencies.s.sol";

contract LocalEthUsdFeed {
    string internal feedDescription;
    uint8 internal feedDecimals;
    uint80 internal roundId;
    int256 internal answer;
    uint256 internal updatedAt;
    uint80 internal answeredInRound;

    constructor(string memory description_, uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        feedDescription = description_;
        feedDecimals = decimals_;
        roundId = 1;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = 1;
    }

    function description() external view returns (string memory) {
        return feedDescription;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    function setDescription(string memory description_) external {
        feedDescription = description_;
    }

    function setDecimals(uint8 decimals_) external {
        feedDecimals = decimals_;
    }

    function setRoundData(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }
}

contract DeploySepoliaDemoDependenciesTest is Test {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 internal constant MAX_PRICE_STALENESS = 1 days;
    int256 internal constant ETH_USD_ANSWER = 2_500e8;

    DeploySepoliaDemoDependencies internal deployer;
    LocalEthUsdFeed internal priceFeed;
    address internal holder;
    address internal recipient;
    address internal spender;

    function setUp() public {
        vm.chainId(SEPOLIA_CHAIN_ID);
        deployer = new DeploySepoliaDemoDependencies();
        priceFeed = new LocalEthUsdFeed("ETH / USD", 8, ETH_USD_ANSWER, block.timestamp);
        holder = makeAddr("holder");
        recipient = makeAddr("recipient");
        spender = makeAddr("spender");
    }

    function test_DeploysBothFixedSupplyTokensWithExactMetadataAndHolderBalance() public {
        (SepoliaDemoERC20 collateralToken, SepoliaDemoERC20 debtToken) = deployer.deploy(_validConfig());

        _assertToken(collateralToken, "Sepolia Demo Ether", "sdETH", 1_000e18);
        _assertToken(debtToken, "Sepolia Demo USD", "sdUSD", 2_000_000e18);
        assertEq(collateralToken.balanceOf(recipient), 0);
        assertEq(debtToken.balanceOf(recipient), 0);
    }

    function test_TokensHaveStandardExactTransferAndTransferFromDeltas() public {
        (SepoliaDemoERC20 collateralToken, SepoliaDemoERC20 debtToken) = deployer.deploy(_validConfig());
        uint256 transferAmount = 12e18;
        uint256 transferFromAmount = 7e18;

        vm.prank(holder);
        assertTrue(collateralToken.transfer(recipient, transferAmount));
        assertEq(collateralToken.balanceOf(holder), 1_000e18 - transferAmount);
        assertEq(collateralToken.balanceOf(recipient), transferAmount);

        vm.prank(holder);
        assertTrue(collateralToken.approve(spender, transferFromAmount));
        vm.prank(spender);
        assertTrue(collateralToken.transferFrom(holder, recipient, transferFromAmount));
        assertEq(collateralToken.balanceOf(holder), 1_000e18 - transferAmount - transferFromAmount);
        assertEq(collateralToken.balanceOf(recipient), transferAmount + transferFromAmount);
        assertEq(collateralToken.allowance(holder, spender), 0);

        vm.prank(holder);
        assertTrue(debtToken.transfer(recipient, transferAmount));
        assertEq(debtToken.balanceOf(holder), 2_000_000e18 - transferAmount);
        assertEq(debtToken.balanceOf(recipient), transferAmount);

        vm.prank(holder);
        assertTrue(debtToken.approve(spender, transferFromAmount));
        vm.prank(spender);
        assertTrue(debtToken.transferFrom(holder, recipient, transferFromAmount));
        assertEq(debtToken.balanceOf(holder), 2_000_000e18 - transferAmount - transferFromAmount);
        assertEq(debtToken.balanceOf(recipient), transferAmount + transferFromAmount);
        assertEq(debtToken.allowance(holder, spender), 0);
    }

    function test_NoPostDeploymentMintPath() public {
        (SepoliaDemoERC20 collateralToken,) = deployer.deploy(_validConfig());
        uint256 initialSupply = collateralToken.totalSupply();

        (bool success,) =
            address(collateralToken).call(abi.encodeWithSignature("mint(address,uint256)", recipient, 1e18));

        assertFalse(success);
        assertEq(collateralToken.totalSupply(), initialSupply);
        assertEq(collateralToken.balanceOf(recipient), 0);
    }

    function test_TokenRejectsZeroInitialHolder() public {
        vm.expectRevert(SepoliaDemoERC20.ZeroInitialHolder.selector);
        new SepoliaDemoERC20("Sepolia Demo Ether", "sdETH", address(0), 1e18);
    }

    function test_TokenRejectsZeroInitialSupply() public {
        vm.expectRevert(SepoliaDemoERC20.ZeroInitialSupply.selector);
        new SepoliaDemoERC20("Sepolia Demo Ether", "sdETH", holder, 0);
    }

    function test_RevertsOnWrongChainForDeploymentPath() public {
        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploySepoliaDemoDependencies.UnexpectedChainId.selector, SEPOLIA_CHAIN_ID, uint256(1)
            )
        );
        deployer.deploy(_validConfig());
    }

    function test_RevertsOnNonSepoliaConfiguredChainWithSuppliedValue() public {
        DeploySepoliaDemoDependencies.DeploymentConfig memory config = _validConfig();
        config.expectedChainId = 1;

        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.InvalidExpectedChainId.selector, uint256(1))
        );
        deployer.validateConfig(config);
    }

    function test_RevertsOnZeroRequiredDeploymentInputs() public {
        DeploySepoliaDemoDependencies.DeploymentConfig memory config = _validConfig();
        config.holder = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.InvalidDemoTokenHolder.selector, address(0))
        );
        deployer.validateConfig(config);

        config = _validConfig();
        config.collateralInitialSupply = 0;
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.InvalidCollateralInitialSupply.selector, uint256(0))
        );
        deployer.validateConfig(config);

        config = _validConfig();
        config.debtInitialSupply = 0;
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.InvalidDebtInitialSupply.selector, uint256(0))
        );
        deployer.validateConfig(config);

        config = _validConfig();
        config.maxPriceStaleness = 0;
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.InvalidMaxPriceStaleness.selector, uint256(0))
        );
        deployer.validateConfig(config);
    }

    function test_RevertsOnZeroOrCodeLessFeed() public {
        DeploySepoliaDemoDependencies.DeploymentConfig memory config = _validConfig();
        config.priceFeed = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploySepoliaDemoDependencies.InvalidPriceFeed.selector, address(0)));
        deployer.validateConfig(config);

        config.priceFeed = makeAddr("codeLessFeed");
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.PriceFeedHasNoCode.selector, config.priceFeed)
        );
        deployer.validateConfig(config);
    }

    function test_RevertsOnWrongFeedDescription() public {
        priceFeed.setDescription("BTC / USD");
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.UnexpectedFeedDescription.selector, "BTC / USD")
        );
        deployer.validateConfig(_validConfig());
    }

    function test_RevertsOnWrongFeedDecimals() public {
        priceFeed.setDecimals(18);
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.UnexpectedFeedDecimals.selector, uint8(18))
        );
        deployer.validateConfig(_validConfig());
    }

    function test_RevertsOnNonpositiveAnswer() public {
        priceFeed.setRoundData(1, 0, block.timestamp, 1);
        vm.expectRevert(abi.encodeWithSelector(DeploySepoliaDemoDependencies.NonPositivePrice.selector, int256(0)));
        deployer.validateConfig(_validConfig());
    }

    function test_RevertsOnZeroTimestamp() public {
        priceFeed.setRoundData(1, ETH_USD_ANSWER, 0, 1);
        vm.expectRevert(DeploySepoliaDemoDependencies.ZeroPriceTimestamp.selector);
        deployer.validateConfig(_validConfig());
    }

    function test_RevertsOnFutureTimestamp() public {
        uint256 futureTimestamp = block.timestamp + 1;
        priceFeed.setRoundData(1, ETH_USD_ANSWER, futureTimestamp, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploySepoliaDemoDependencies.FuturePriceTimestamp.selector, futureTimestamp, block.timestamp
            )
        );
        deployer.validateConfig(_validConfig());
    }

    function test_RevertsOnStalePrice() public {
        vm.warp(MAX_PRICE_STALENESS + 2);
        uint256 staleTimestamp = block.timestamp - MAX_PRICE_STALENESS - 1;
        priceFeed.setRoundData(1, ETH_USD_ANSWER, staleTimestamp, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploySepoliaDemoDependencies.StalePrice.selector, staleTimestamp, block.timestamp, MAX_PRICE_STALENESS
            )
        );
        deployer.validateConfig(_validConfig());
    }

    function test_RevertsOnIncompleteRound() public {
        priceFeed.setRoundData(2, ETH_USD_ANSWER, block.timestamp, 1);
        vm.expectRevert(
            abi.encodeWithSelector(DeploySepoliaDemoDependencies.IncompleteRound.selector, uint80(2), uint80(1))
        );
        deployer.validateConfig(_validConfig());
    }

    function test_SuccessfulValidEthUsdFeedPreflight() public view {
        DeploySepoliaDemoDependencies.FeedRoundData memory data = deployer.validateConfig(_validConfig());

        assertEq(data.roundId, 1);
        assertEq(data.answer, ETH_USD_ANSWER);
        assertEq(data.updatedAt, block.timestamp);
        assertEq(data.answeredInRound, 1);
    }

    function test_18DecimalCollateralWadPriceMapsTo18DecimalDebtRawUnits() public view {
        uint256 collateralRaw = 2.5e18;
        uint256 priceWad = deployer.normalizedEthUsdPriceWad(ETH_USD_ANSWER, 8);

        assertEq(priceWad, 2_500e18);
        assertEq(deployer.collateralRawToDebtRaw(collateralRaw, priceWad), 6_250e18);
    }

    function test_NegativeAnswerCannotBeNormalized() public {
        vm.expectRevert(abi.encodeWithSelector(DeploySepoliaDemoDependencies.NonPositivePrice.selector, int256(-1)));
        deployer.normalizedEthUsdPriceWad(-1, 8);
    }

    function _validConfig() internal view returns (DeploySepoliaDemoDependencies.DeploymentConfig memory) {
        return DeploySepoliaDemoDependencies.DeploymentConfig({
            holder: holder,
            collateralInitialSupply: 1_000e18,
            debtInitialSupply: 2_000_000e18,
            priceFeed: address(priceFeed),
            maxPriceStaleness: MAX_PRICE_STALENESS,
            expectedChainId: SEPOLIA_CHAIN_ID
        });
    }

    function _assertToken(
        SepoliaDemoERC20 token,
        string memory expectedName,
        string memory expectedSymbol,
        uint256 supply
    ) internal view {
        assertGt(address(token).code.length, 0);
        assertEq(token.name(), expectedName);
        assertEq(token.symbol(), expectedSymbol);
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(holder), supply);
    }
}
