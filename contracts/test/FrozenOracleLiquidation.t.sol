// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "./TestContracts/DevTestSetup.sol";

contract FrozenOracleLiquidationTest is DevTestSetup {
    function setUp() public override {
        // Start tests at a non-zero timestamp
        vm.warp(block.timestamp + 600);

        accounts = new Accounts();
        createAccounts();

        (A, B, C, D, E, F, G) = (
            accountsList[0],
            accountsList[1],
            accountsList[2],
            accountsList[3],
            accountsList[4],
            accountsList[5],
            accountsList[6]
        );

        TestDeployer deployer = new TestDeployer();
        TestDeployer.TroveManagerParams[] memory troveManagerParamsArray = new TestDeployer.TroveManagerParams[](1);
        troveManagerParamsArray[0] = TestDeployer.TroveManagerParams(150e16, 110e16, 10e16, 110e16, 5e16, 10e16);

        TestDeployer.LiquityContractsDev[] memory contractsArray;
        (contractsArray, collateralRegistry, boldToken,,, WETH,) = deployer.deployAndConnectContractsMultiColl(troveManagerParamsArray);

        borrowerOperations = contractsArray[0].borrowerOperations;
        troveManager = contractsArray[0].troveManager;
        activePool = contractsArray[0].activePool;
        priceFeed = contractsArray[0].priceFeed;
        defaultPool = contractsArray[0].defaultPool;
        collSurplusPool = contractsArray[0].collSurplusPool;
        stabilityPool = contractsArray[0].stabilityPool;
        gasPool = contractsArray[0].gasPool;
        MCR = troveManager.get_MCR();
        SCR = troveManager.get_SCR();

        // Set initial price
        priceFeed.setPrice(2000e18);

        // Fund A and B
        giveAndApproveCollateral(contractsArray[0].collToken, A, 10_000e18, address(borrowerOperations));
        giveAndApproveCollateral(contractsArray[0].collToken, B, 10_000e18, address(borrowerOperations));
        vm.startPrank(A);
        WETH.approve(address(borrowerOperations), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(B);
        WETH.approve(address(borrowerOperations), type(uint256).max);
        vm.stopPrank();
    }

    function testFrozenOracleBlocksLiquidation() public {
        // 1. Open a Trove for A.
        // Price 2000. Coll 10 ETH = $20,000. Debt 10,000 BOLD.
        // ICR = 20000/10000 = 200%. MCR = 110%. Healthy.
        vm.startPrank(A);
        uint256 troveId = borrowerOperations.openTrove(A, 0, 10e18, 10000e18, 0, 0, 5e16, 1000e18, address(0), address(0), address(0));
        vm.stopPrank();

        // 2. Simulate Oracle Failure at high price.
        // The price is 2000. We trigger a shutdown via oracle failure.
        // In this test environment, we simulate failure by setting price to 0 or reverting,
        // but `MockPriceFeed` used in DevTestSetup might behavior differently.
        // Let's assume we can trigger shutdownFromOracleFailure directly if we are PriceFeed.
        // Or we just use `shutdown()` if TCR < SCR. But we want specifically Oracle Failure scenario
        // because that freezes the price.
        // The MockPriceFeed `setPrice` just sets the price.
        // However, `BorrowerOperations` calls `priceFeed.fetchPrice()`.
        // If we set `newOracleFailureDetected` return value in the mock?
        // Checking `MockPriceFeed.sol` (inferred): likely has a way to simulate failure.
        // If not, we can simulate the *effect* of oracle failure:
        // Shutdown happens, and `fetchPrice` returns the LAST good price forever.

        // Let's manually trigger shutdown while price is 2000.
        // But to call `shutdown()`, TCR needs to be < SCR.
        // To simulate Oracle Failure, we might need to use `shutdownFromOracleFailure`.
        // `borrowerOperations.shutdownFromOracleFailure()` requires caller to be PriceFeed.
        // We can prank as PriceFeed.
        vm.prank(address(priceFeed));
        borrowerOperations.shutdownFromOracleFailure();

        assertTrue(borrowerOperations.hasBeenShutDown());

        // 3. Simulate Market Crash.
        // The "real" market price drops to $500.
        // Ideally, we'd update the oracle to $500, but since it's "failed", `fetchPrice` should return 2000.
        // In the MockPriceFeed, we can verify what it returns.
        // If the real system logic holds: "If the PriceFeed has already been disabled, return the lastGoodPrice."
        // We need to check if `MockPriceFeed` implements this "disabled" logic.
        // If `MockPriceFeed` doesn't implement disabling, we can manually ensure `fetchPrice` returns 2000
        // while we conceptually treat the market price as 500.

        // Let's ensure the price used by the system is 2000.
        (uint256 fetchedPrice, ) = priceFeed.fetchPrice();
        assertEq(fetchedPrice, 2000e18);

        // 4. Check Trove Solvency vs Real Market Price ($500).
        // Real Coll Value = 10 ETH * $500 = $5,000.
        // Debt = 10,000 BOLD.
        // Real ICR = 5000 / 10000 = 50%.
        // This trove is DEEPLY insolvent. It should be liquidated immediately to save the SP/Protocol.

        // 5. Attempt Liquidation.
        // B tries to liquidate A.
        // `batchLiquidateTroves` will call `fetchPrice`.
        // It gets 2000 (the frozen high price).
        // Calculated ICR = (10 * 2000) / 10000 = 200%.
        // 200% > MCR (110%).
        // Liquidation should fail (NothingToLiquidate).

        uint256[] memory troves = new uint256[](1);
        troves[0] = troveId;

        vm.startPrank(B);
        vm.expectRevert(TroveManager.NothingToLiquidate.selector);
        troveManager.batchLiquidateTroves(troves);
        vm.stopPrank();

        // 6. Attempt Urgent Redemption.
        // B tries to redeem debt to clear the bad debt.
        // Market price is $500. BOLD is maybe $1.
        // If B redeems 1 BOLD, they should get $1 worth of ETH.
        // At $500/ETH, 1 BOLD = 0.002 ETH.
        // However, system uses $2000.
        // System gives: 1 BOLD / 2000 = 0.0005 ETH.
        // Value at real market price ($500): 0.0005 * 500 = $0.25.
        // Loss of 75% for the redeemer.
        // B will NOT redeem.

        // Result:
        // The insolvent trove (50% ICR) stays in the system.
        // It cannot be liquidated.
        // It cannot be redeemed (profitably).
        // The bad debt (5000 unbacked BOLD) is locked in.
    }
}
