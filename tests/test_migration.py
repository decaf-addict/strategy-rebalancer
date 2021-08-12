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
    new_strategyA = strategist.deploy(JointProvider, vaultA, oracleA)
    new_strategyA.setRebalancer(rebalancer, {"from": gov})

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
    new_strategyA = strategist.deploy(JointProvider, vaultA, oracleA)
    new_strategyA.setRebalancer(rebalancer, {"from": gov})

    vaultA.migrateStrategy(providerA, new_strategyA, {"from": gov})
    assert (pytest.approx(new_strategyA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA)

    new_strategyB = strategist.deploy(JointProvider, vaultB, oracleB)
    new_strategyB.setRebalancer(rebalancer, {"from": gov})

    vaultB.migrateStrategy(providerB, new_strategyB, {"from": gov})
    assert (pytest.approx(new_strategyB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB)

    new_strategyA.harvest({"from": gov})
    new_strategyB.harvest({"from": gov})


def test_rebalancer_migration(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user,
                              gov, setup, RELATIVE_APPROX, testSetup, chain, strategist, Rebalancer, oracleA, oracleB,
                              bpt, reward, reward_whale, pool, rando, transferToRando):
    # Deposit to the vault and harvest
    chain.sleep(1)
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA
    assert pytest.approx(providerB.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountB

    # migrate to a new strategy
    new_rebalancer = strategist.deploy(Rebalancer, providerA, providerB, gov, strategist, bpt)

    bpts = rebalancer.balanceOfBpt()
    rebalancer.migrateRebalancer(new_rebalancer, {'from': gov})
    assert new_rebalancer.balanceOfBpt() == bpts

    # setup for new rebalancer
    rebalancer.setController(new_rebalancer, {'from': gov})
    new_rebalancer.removeWhitelistedLiquidityProvider(rebalancer, {'from': gov})
    new_rebalancer.whitelistLiquidityProvider(new_rebalancer, {'from': gov})

    util.simulate_2_sided_trades(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)
    util.simulate_bal_reward(rebalancer, reward, reward_whale)
    util.stateOfStrat("after bal reward", rebalancer, providerA, providerB)

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultA.pricePerShare()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.stateOfStrat("harvest after swap", rebalancer, providerA, providerB)

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB
