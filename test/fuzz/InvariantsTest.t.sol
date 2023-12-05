// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {StdInvariant} from "lib/forge-std/src/StdInvariant.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeploySC} from "../../script/DeploySC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DSCEngine engine;
    StableCoin sc;
    DeploySC deployer;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeploySC();
        (sc, engine, config) = deployer.run();
        (, , weth, wbtc, ) = config.activeNetwork();

        handler = new Handler(engine, sc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveCollateralAmountMoreThanTotalSupply()
        external
        view
    {
        uint totalSupplyWeth = IERC20(weth).totalSupply();
        uint totalSupplyWbtc = IERC20(wbtc).totalSupply();
        uint totalScMinted = sc.totalSupply();

        console.log("Total supply weth : ", totalSupplyWeth);
        console.log("Total supply wbtc : ", totalSupplyWbtc);
        console.log("Total sc minted : ", totalScMinted);
        console.log("Times mint Function Called : ", handler.called());

        assert(totalSupplyWeth + totalSupplyWbtc >= totalScMinted);
    }

    function invariants_gettersCantRevert() external view {
        engine.get_ADDITIONAL_FEED_PRECISION();
        engine.get_PRECISION();
        engine.get_LIQUIDATION_BONUS();
        engine.getCollateralTokens();
        engine.get_MIN_HEALTH_FACTOR();
        engine.get_LIQUIDATION_THRESHOLD();
        engine.get_Sc();
        engine.get_LIQUIDATION_PRECISION();
    }
}
