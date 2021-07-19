import pytest
import util


def test_1_migration_harvest(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user,
                             gov,
                             setup, RELATIVE_APPROX, testSetup, chain, strategist, JointProvider, oracleA, oracleB
                             ):
    # Deposit to the vault and harvest
    chain.sleep(1)
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(providerB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB

    # migrate to a new strategy
    new_strategyA = strategist.deploy(JointProvider, vaultA, rebalancer, oracleA)
    vaultA.migrateStrategy(providerA, new_strategyA, {"from": gov})
    assert (pytest.approx(new_strategyA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA)

    new_strategyA.harvest({"from": gov})


def test_2_migrations_harvest(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user,
                              gov,
                              setup, RELATIVE_APPROX, testSetup, chain, strategist, JointProvider, oracleA, oracleB
                              ):
    # Deposit to the vault and harvest
    chain.sleep(1)
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(providerB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB

    # migrate to a new strategy
    new_strategyA = strategist.deploy(JointProvider, vaultA, rebalancer, oracleA)
    vaultA.migrateStrategy(providerA, new_strategyA, {"from": gov})
    assert (pytest.approx(new_strategyA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA)

    new_strategyB = strategist.deploy(JointProvider, vaultB, rebalancer, oracleB)
    vaultB.migrateStrategy(providerB, new_strategyB, {"from": gov})
    assert (pytest.approx(new_strategyB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB)

    new_strategyA.harvest({"from": gov})
    new_strategyB.harvest({"from": gov})


def test_rebalancer_migration(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user,
                              gov, setup, RELATIVE_APPROX, testSetup, chain, strategist, Rebalancer, oracleA, oracleB,
                              bpt):
    # Deposit to the vault and harvest
    chain.sleep(1)
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(providerB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB

    # migrate to a new strategy
    new_rebalancer = strategist.deploy(Rebalancer, gov, bpt)
    rebalancer.migrateRebalancer(new_rebalancer, {'from': gov})

    # setup for new rebalancer
    new_rebalancer.setProviders(providerA, providerB, {'from': gov})
    rebalancer.setController(new_rebalancer, {'from': gov})
    new_rebalancer.removeWhitelistedLiquidityProvider(rebalancer, {'from': gov})
    new_rebalancer.whitelistLiquidityProvider(new_rebalancer, {'from': gov})

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})
