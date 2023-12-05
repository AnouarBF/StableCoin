// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "lib/forge-std/src/Script.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {StableCoin} from "../src/StableCoin.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeploySC is Script {
    address[] private tokenAddress;
    address[] private priceFeedAddress;
    HelperConfig hc;

    function run()
        external
        returns (
            StableCoin,
            DSCEngine,
            HelperConfig
        )
    {
        hc = new HelperConfig();
        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc,

        ) = hc.activeNetwork();

        tokenAddress = [weth, wbtc];
        priceFeedAddress = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(); //////////////////////////////////////////////////////////////////////////////////
        StableCoin stableCoin = new StableCoin();
        DSCEngine engine = new DSCEngine(
            tokenAddress,
            priceFeedAddress,
            address(stableCoin)
        );
        // We should transfer ownership of the coin to the engine in order to make it controlable by the engine.
        stableCoin.transferOwnership(address(engine));
        vm.stopBroadcast(); ////////////////////////////////////////////////////////////////////////////////////

        return (stableCoin, engine, hc);
    }
}
