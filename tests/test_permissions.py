import brownie


def test_permissions(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user, gov,
                     setup, RELATIVE_APPROX, testSetup, rando):
    with brownie.reverts():
        rebalancer.collectTradingFees({'from': rando})

    with brownie.reverts():
        rebalancer.sellRewards({'from': rando})

    with brownie.reverts():
        rebalancer.adjustPosition({'from': rando})

    with brownie.reverts():
        rebalancer.liquidatePosition(1, tokenA, rando, {'from': rando})

    with brownie.reverts():
        rebalancer.liquidateAllPositions(tokenA, rando, {'from': rando})

    with brownie.reverts():
        rebalancer.setProviders(providerA, providerB, {'from': rando})

    with brownie.reverts():
        rebalancer.setController(rebalancer, {'from': rando})

    with brownie.reverts():
        rebalancer.setSwapFee(0.003 * 1e18, {'from': rando})

    with brownie.reverts():
        rebalancer.setPublicSwap(False, {'from': rando})

    with brownie.reverts():
        rebalancer.whitelistLiquidityProvider(rando, {'from': rando})

    with brownie.reverts():
        rebalancer.removeWhitelistedLiquidityProvider(rando, {'from': rando})

    with brownie.reverts():
        rebalancer.migrateProvider(rando, {'from': rando})

    with brownie.reverts():
        rebalancer.migrateRebalancer(rando, {'from': rando})
