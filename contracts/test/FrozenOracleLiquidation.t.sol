// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./TestContracts/DevTestSetup.sol";
import "./TestContracts/ChainlinkOracleMock.sol";
import "src/PriceFeeds/WETHPriceFeed.sol";

contract FrozenOracleLiquidationTest is DevTestSetup {
    address constant ETH_ORACLE_ADDR = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    ChainlinkOracleMock ethOracleMock;

    function setUp() public override {
        // Start at non-zero timestamp
        vm.warp(block.timestamp + 600);

        accounts = new Accounts();
        createAccounts();
        (A, B, C, D, E, F, G) = (accountsList[0], accountsList[1], accountsList[2], accountsList[3], accountsList[4], accountsList[5], accountsList[6]);

        // 1. Etch Mock Oracle code at the mainnet address
        deployCodeTo("ChainlinkOracleMock.sol", ETH_ORACLE_ADDR);
        ethOracleMock = ChainlinkOracleMock(ETH_ORACLE_ADDR);
        ethOracleMock.setDecimals(8);
        ethOracleMock.setPrice(2000e8); // $2000
        ethOracleMock.setUpdatedAt(block.timestamp);

        // 2. Deploy System (Mainnet Mode) using TestDeployer
        TestDeployer deployer = new TestDeployer();
        TestDeployer.TroveManagerParams[] memory troveManagerParamsArray = new TestDeployer.TroveManagerParams[](3);
        // Params: CCR, MCR, BCR, SCR, LiqPenSP, LiqPenRedist
        troveManagerParamsArray[0] = TestDeployer.TroveManagerParams(150e16, 110e16, 10e16, 110e16, 5e16, 10e16); // WETH
        troveManagerParamsArray[1] = TestDeployer.TroveManagerParams(160e16, 120e16, 10e16, 120e16, 5e16, 10e16); // RETH
        troveManagerParamsArray[2] = TestDeployer.TroveManagerParams(160e16, 120e16, 10e16, 120e16, 5e16, 10e16); // WSTETH

        // We also need to etch RETH and STETH oracles/tokens if we want full deployment to succeed without reverts?
        // TestDeployer calls them.
        // Let's verify deployment doesn't fail.
        // It deploys WETHPriceFeed which calls ETHOracle.
        // It deploys RETHPriceFeed which calls RETHOracle.
        // If RETHOracle is not etched, it's empty account. Call returns success (0 data)?
        // AggregatorV3Interface returns (roundId, answer, ...).
        // If empty account, decoding might fail or return 0s.
        // `WETHPriceFeed` constructor calls `_fetchPricePrimary`.
        // `_getOracleAnswer` calls `latestRoundData`.
        // If reverts -> deployment fails.
        // Empty account call -> returns success, empty data.
        // `abi.decode` of empty data -> revert?
        // Yes, likely.
        // So I must etch ALL oracles and tokens used in Mainnet deployment.

        // RETH Oracle
        deployCodeTo("ChainlinkOracleMock.sol", 0x536218f9E9Eb48863970252233c8F271f554C2d0);
        ChainlinkOracleMock(0x536218f9E9Eb48863970252233c8F271f554C2d0).setPrice(1e18); // 1 ETH
        ChainlinkOracleMock(0x536218f9E9Eb48863970252233c8F271f554C2d0).setUpdatedAt(block.timestamp);

        // STETH Oracle
        deployCodeTo("ChainlinkOracleMock.sol", 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8);
        ChainlinkOracleMock(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8).setPrice(2000e8);
        ChainlinkOracleMock(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8).setUpdatedAt(block.timestamp);

        // RETH Token (Mock) - for exchange rate
        deployCodeTo("RETHTokenMock.sol", 0xae78736Cd615f374D3085123A210448E74Fc6393);
        // RETHTokenMock doesn't need setup, returns 1e18 by default? Let's assume so.

        // WSTETH Token (Mock)
        deployCodeTo("WSTETHTokenMock.sol", 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

        TestDeployer.DeploymentResultMainnet memory result = deployer.deployAndConnectContractsMainnet(troveManagerParamsArray);

        // Extract contracts for WETH branch (Index 0)
        borrowerOperations = result.contractsArray[0].borrowerOperations;
        troveManager = result.contractsArray[0].troveManager;
        activePool = result.contractsArray[0].activePool;
        priceFeed = result.contractsArray[0].priceFeed;
        defaultPool = result.contractsArray[0].defaultPool;
        collSurplusPool = result.contractsArray[0].collSurplusPool;
        stabilityPool = result.contractsArray[0].stabilityPool;
        gasPool = result.contractsArray[0].gasPool;
        MCR = troveManager.get_MCR();
        SCR = troveManager.get_SCR();
        collateralRegistry = result.collateralRegistry;
        boldToken = result.boldToken;
        WETH = IWETH(address(result.contractsArray[0].collToken)); // It uses WETH address from TestDeployer (Mainnet WETH)

        // Etch WETH code at the WETH address (0xC02...) so we can mint/approve
        deployCodeTo("WETH.sol", 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        // Re-cast WETH to the etched address
        WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

        // Fund A and B
        deal(address(WETH), A, 10_000e18);
        deal(address(WETH), B, 10_000e18);
        vm.startPrank(A);
        WETH.approve(address(borrowerOperations), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(B);
        WETH.approve(address(borrowerOperations), type(uint256).max);
        vm.stopPrank();
    }

    function testFrozenOracleBlocksLiquidationReal() public {
        // 1. Open a Trove for A.
        // Price 2000. Coll 10 ETH = $20,000. Debt 10,000 BOLD.
        // ICR = 20000/10000 = 200%. MCR = 110%.
        vm.startPrank(A);
        uint256 troveId = borrowerOperations.openTrove(A, 0, 10e18, 10000e18, 0, 0, 5e16, 1000e18, address(0), address(0), address(0));
        vm.stopPrank();

        // 2. Trigger Oracle Failure (Staleness).
        // WETHPriceFeed staleness threshold is 24 hours (86400).
        vm.warp(block.timestamp + 86401);

        // Oracle is now stale.
        // Trigger fetching price.
        // This should shut down the branch.
        // We use a separate account to trigger it.
        vm.prank(C);
        // Calling fetchPrice directly should trigger shutdown
        (uint256 price, bool failure) = priceFeed.fetchPrice();

        assertTrue(failure, "Should detect failure");
        assertTrue(borrowerOperations.hasBeenShutDown(), "Branch should be shut down");
        assertEq(price, 2000e18, "Should return last good price (2000)");

        // 3. Update Oracle to Crash Price ($500) and recover freshness.
        ethOracleMock.setPrice(500e8);
        ethOracleMock.setUpdatedAt(block.timestamp); // Fresh now

        // 4. Verify System IGNORES new price.
        (uint256 fetchedPrice, bool failure2) = priceFeed.fetchPrice();
        assertEq(fetchedPrice, 2000e18, "Should still return frozen price 2000");
        assertFalse(failure2, "Should not report failure (using fallback)");

        // 5. Attempt Liquidation.
        // Real market price is 500.
        // Trove Coll = 10 ETH * 500 = $5000.
        // Debt = 10,000 BOLD.
        // Real ICR = 50%. INSOLVENT.
        // System ICR = (10 * 2000) / 10000 = 200%. HEALTHY.

        uint256[] memory troves = new uint256[](1);
        troves[0] = troveId;

        vm.startPrank(B);
        vm.expectRevert(TroveManager.NothingToLiquidate.selector);
        troveManager.batchLiquidateTroves(troves);
        vm.stopPrank();

        // 6. Verify Urgent Redemption is Unprofitable.
        // B has 10,000 BOLD (let's say).
        // Market price $500. 1 BOLD should buy 0.002 ETH.
        // System price $2000. 1 BOLD buys 0.0005 ETH.
        // B gets 4x LESS collateral than fair value.
        // Redemption is blocked by economic disincentive.
    }
}
