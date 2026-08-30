// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LendingPool} from "../../src/core/lending/LendingPool.sol";

abstract contract LendingPoolProxyFixture {
    struct LendingPoolProxyConfig {
        address priceFeed;
        address vault;
        address debtAsset;
        uint256 maxPriceStaleness;
        uint256 ltvBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 baseBorrowRate;
        uint256 borrowRateSlope;
        address initialUpgradeAuthority;
    }

    function _deployLendingPoolProxy(LendingPoolProxyConfig memory config)
        internal
        returns (LendingPool poolProxy, LendingPool implementation)
    {
        implementation = new LendingPool();
        poolProxy = _deployLendingPoolProxy(implementation, config);
    }

    function _deployLendingPoolProxy(LendingPool implementation, LendingPoolProxyConfig memory config)
        internal
        returns (LendingPool poolProxy)
    {
        bytes memory initializationData = abi.encodeCall(
            LendingPool.initialize,
            (
                config.priceFeed,
                config.vault,
                config.debtAsset,
                config.maxPriceStaleness,
                config.ltvBps,
                config.liquidationThresholdBps,
                config.liquidationBonusBps,
                config.baseBorrowRate,
                config.borrowRateSlope,
                config.initialUpgradeAuthority
            )
        );

        poolProxy = LendingPool(address(new ERC1967Proxy(address(implementation), initializationData)));
    }
}
