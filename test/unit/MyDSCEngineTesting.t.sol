// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {DeploySC} from "../../script/DeploySC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {StableCoin} from "../../src/StableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract MyScEngineTest is Test {
    event DepositedCollateral(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    event RedeemedCollateral(
        address indexed from,
        address indexed to,
        address token,
        uint amount
    );

    DeploySC deployer;
    StableCoin sc;
    DSCEngine engine;
    HelperConfig hc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public OTHER_USER = makeAddr("other user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint public constant AMOUNT_TO_MINT = 100000;
    uint public constant AMOUNT_TO_LIQUIDATE = 20 ether;

    function setUp() external {
        deployer = new DeploySC();
        (sc, engine, hc) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = hc.activeNetwork();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    modifier deposit(address user) {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateral(address user) {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositAndMint(address user) {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintSc(
            address(weth),
            AMOUNT_COLLATERAL,
            AMOUNT_TO_MINT
        );
        vm.stopPrank();
        _;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Constructor/////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testConstructorRevertIfTokensNumberDoesnotEqualToPriceFeedNumber()
        external
    {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__tokenAddressLengthAndPriceFeedAddressLengthAreNotEqual
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(sc));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Price Test ////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////

    function testGetTokenAmountFromUsd() public {
        uint usdAmount = 100 ether;
        uint expectedWeth = 0.05 ether;
        uint actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    //Deposit collateral /////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_depositCollateral_revertsIfTransferFromFails() external {
        vm.startPrank(USER);
        MockFailedTransferFrom mockSc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockSc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockSc)
        );
        mockSc.transferOwnership(address(mockEngine));

        ERC20Mock(address(mockSc)).approve(
            address(mockEngine),
            AMOUNT_COLLATERAL
        );
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.depositCollateral(address(mockSc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__CannotDepositZeroAmount.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfTokenNotValid() external {
        ERC20Mock randToken = new ERC20Mock(
            "RAN",
            "RAN",
            USER,
            STARTING_ERC20_BALANCE
        );
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressNotValid.selector);
        engine.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testReentrancy() external {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.expectRevert();
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCheckCollateralAmountDeposited() external {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();

        assert(
            engine.getCollateralAmountDeposited(USER, address(weth)) ==
                AMOUNT_COLLATERAL
        );
    }

    function testEvent_DepositedCollateral() external {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, false);
        emit DepositedCollateral(USER, weth, AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Test MintSc ///////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////

    function testMintNonZeroAmount() external {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintSc(AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function test_MintSc_revertsIfHealthFactorIsBroken() external {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();

        uint amountToMint = (AMOUNT_COLLATERAL *
            (uint(price) * engine.get_ADDITIONAL_FEED_PRECISION())) /
            engine.get_PRECISION();

        vm.startPrank(USER); //********************************************************************************
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        uint expectedHealthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, AMOUNT_COLLATERAL)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        engine.depositCollateralAndMintSc(
            address(weth),
            AMOUNT_COLLATERAL,
            amountToMint
        );
        vm.stopPrank(); //*************************************************************************************
    }

    function test_mintSc_revertsIfMintedAmountBreaksHealthFactor()
        external
        depositCollateral(USER)
    {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();

        uint amountToMint = (AMOUNT_COLLATERAL *
            (uint(price) * engine.get_ADDITIONAL_FEED_PRECISION())) /
            engine.get_PRECISION();

        vm.startPrank(USER); //********************************************************************************
        uint expectedHealthFactor = engine.calculateHealthFactor(
            amountToMint,
            engine.getUsdValue(weth, AMOUNT_COLLATERAL)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        engine.mintSc(amountToMint);
        vm.stopPrank(); //*************************************************************************************
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Test Health Factor ////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_getAccountCollateralValue() external deposit(USER) {
        uint value = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(engine.getAccountCollateralValue(USER), value);
    }

    function test_getAccountInformation() external deposit(USER) {
        (uint256 totalDscMinted, uint256 collateredValueInUsd) = engine
            .getAccountInformation(USER);
        assert(
            totalDscMinted == engine.getMinted_Sc(USER) &&
                collateredValueInUsd == engine.getAccountCollateralValue(USER)
        );
    }

    function test_healthFactor() external depositAndMint(USER) {
        (uint256 totalDscMinted, uint256 collateredValueInUsd) = engine
            .getAccountInformation(USER);

        uint liquidationThreshold = engine.get_LIQUIDATION_THRESHOLD();

        uint collateralAdjustedForThreshold = (collateredValueInUsd *
            liquidationThreshold) / 100;

        uint healthFactor = (collateralAdjustedForThreshold *
            liquidationThreshold) / totalDscMinted;

        assert(engine.getHealthFactor(USER) == healthFactor);
    }

    function test_revertIfHealthFactorIsBroken() external deposit(USER) {
        vm.prank(USER);
        engine.mintSc(AMOUNT_TO_MINT);
        uint userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor > 1e18);
    }

    /**
     * @dev this `test_RevertErrorIfHealthFactorIsBroken` didn't pass!!
     */
    // function test_RevertErrorIfHealthFactorIsBroken() external {
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
    //     engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
    //     engine.mintSc(AMOUNT_TO_MINT);
    //     uint userHealthFactor = (engine.getHealthFactor(USER));
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             DSCEngine.DSCEngine__BreaksHealthFactor.selector,
    //             userHealthFactor
    //         )
    //     );
    //     vm.stopPrank();
    // }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Test Redumption //////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_redeemCollateral_revertsIfTransferFailed() external {
        vm.startPrank(USER);
        MockFailedTransfer mockSc = new MockFailedTransfer();
        tokenAddresses = [address(mockSc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockSc)
        );
        mockSc.mint(USER, AMOUNT_COLLATERAL);

        mockSc.transferOwnership(address(mockEngine));

        ERC20Mock(address(mockSc)).approve(
            address(mockEngine),
            AMOUNT_COLLATERAL
        );
        mockEngine.depositCollateral(address(mockSc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.redeemCollateral(address(mockSc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_redeemCollateral_ShouldRevertIfRedeemedAmountIsZero()
        external
        depositAndMint(USER)
    {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__CannotDepositZeroAmount.selector);
        engine.redeemCollateral(address(weth), 0);
        vm.stopPrank();
    }

    // @dev this test is passing for the first assertion. But the second one doesn't
    // Could be because the @param AMOUNT_COLLATERAL is less than the @param userBalance
    // @param AMOUNT_COLLATERAL =   10000000000000000000
    // @param userBalance       =   100000000000000000000

    function test_redeemCollateral_properlyWorking()
        external
        depositCollateral(OTHER_USER)
    {
        vm.prank(OTHER_USER);

        vm.prank(OTHER_USER);
        engine.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
        uint new_collateralAmountDeposited = engine
            .getCollateralAmountDeposited(OTHER_USER, address(weth));
        uint userBalance = ERC20Mock(weth).balanceOf(OTHER_USER);
        assert(new_collateralAmountDeposited == 0);
        // console.log(userBalance);
        // console.log(AMOUNT_COLLATERAL);
        assert(userBalance == AMOUNT_COLLATERAL);
    }

    /**
     * @dev this one blows my mind, "expectEmit" not found or not visible
     */

    // function test_redeemCollateral_ShouldEmitTheRedeemedEvent()
    //     external
    //     depositCollateral
    // {
    //     vm.prank(USER);
    //     vm.expectEmit(true, true, false, true, true, address(engine));
    //     emit RedeemedCollateral(
    //         address(engine),
    //         address(USER),
    //         address(weth),
    //         AMOUNT_COLLATERAL
    //     );
    //     vm.startPrank(USER);
    //     engine.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
    //     vm.stopPrank();
    // }

    function test_ShouldRevert_BreaksHealthFactor_IfAllCollateralRedeemed()
        external
        depositAndMint(USER)
    {
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                0
            )
        );
        engine.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Test Burn /////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_burnDsc() external depositAndMint(USER) {
        vm.startPrank(USER);
        sc.approve(address(engine), AMOUNT_TO_MINT);
        engine.burnDsc(AMOUNT_TO_MINT);
        vm.stopPrank();
        assert(engine.getMinted_Sc(USER) < AMOUNT_TO_MINT);
    }

    function test_burnDsc_MoreThanZero() external depositAndMint(USER) {
        vm.startPrank(USER);
        sc.approve(address(engine), AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__CannotDepositZeroAmount.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    function test_burnDsc_cannotBurnMoreThanBalance() external {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    //////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Test redeemCollateralForDsc //////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_redeemCollateralForDsc() external depositAndMint(USER) {
        vm.startPrank(USER);
        sc.approve(address(engine), AMOUNT_TO_MINT);
        engine.redeemCollateralForDsc(
            address(weth),
            AMOUNT_COLLATERAL,
            AMOUNT_TO_MINT
        );
        vm.stopPrank();
        uint currentCollateralBalance = engine.getCollateralAmountDeposited(
            USER,
            address(weth)
        );
        assert(currentCollateralBalance == 0);
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Liquidate testing ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_liquidate_cannotLiquidateLZeroAmount() external {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__CannotDepositZeroAmount.selector);
        engine.liquidate(address(sc), USER, 0);
        vm.stopPrank();
    }

    function test_liquidate_revertsHealthFactorOk() external {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactor_Ok.selector);
        engine.liquidate(address(sc), USER, AMOUNT_TO_LIQUIDATE);
        vm.stopPrank();
    }
    /////////////////////////
}
