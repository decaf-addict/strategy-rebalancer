import brownie


def test_permissions(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user, gov,
                     setup, RELATIVE_APPROX, testSetup, rando):
    with brownie.reverts("Not rebalancer!"):
        providerA.migrateRebalancer(rando, {'from': rando})

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
        rebalancer.setSwapFee(0.003 * 1e18, {'from': rando})

    with brownie.reverts():
        rebalancer.setPublicSwap(False, {'from': rando})

    with brownie.reverts():
        rebalancer.migrateProvider(rando, {'from': rando})

    with brownie.reverts():
        providerA.migrateRebalancer(rando, {'from': rando})

    with brownie.reverts():
        providerA.setRebalancer(rando, {'from': rando})
