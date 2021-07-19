import brownie
from brownie import Contract
import pytest
import util


def test_change_debt(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user, gov,
                     setup, RELATIVE_APPROX, chain, testSetup):
    beforeBpt = rebalancer.balanceOfBpt()
    util.stateOfStrat("before harvest", rebalancer, providerA, providerB)

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    vaultA.updateStrategyDebtRatio(providerA.address, 5_000, {"from": gov})

    # Deposit to the vault and harvest
    chain.sleep(1)
    providerA.harvest({"from": gov})
    half = int(amountA / 2)
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half
    util.stateOfStrat("harvest at 5000", rebalancer, providerA, providerB)

    vaultA.updateStrategyDebtRatio(providerA.address, 10_000, {"from": gov})
    chain.sleep(1)
    providerA.harvest()
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amountA
    util.stateOfStrat("harvest at 10000", rebalancer, providerA, providerB)

    vaultA.updateStrategyDebtRatio(providerA.address, 5_000, {"from": gov})
    chain.sleep(1)
    providerA.harvest()
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half
    util.stateOfStrat("harvest at 5000", rebalancer, providerA, providerB)

    vaultA.updateStrategyDebtRatio(providerA.address, 0, {"from": gov})
    chain.sleep(1)
    providerA.harvest()

    # exiting everything out should leave only seed amount which will always be kept in the pool
    assert rebalancer.balanceOfBpt() == rebalancer.seedBptAmount()

    # the estimatedTotalAssets of adapterA should now be the seed amount for A
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == rebalancer.pooledBalanceA()
    util.stateOfStrat("harvest at 0", rebalancer, providerA, providerB)


def test_profitable_change_debt(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer,
                                user, gov,
                                setup, RELATIVE_APPROX, chain, testSetup, pool, transferToRando, rando):
    beforeBpt = rebalancer.balanceOfBpt()
    util.stateOfStrat("before harvest", rebalancer, providerA, providerB)

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    vaultA.updateStrategyDebtRatio(providerA.address, 5_000, {"from": gov})

    # Deposit to the vault and harvest
    chain.sleep(1)
    providerA.harvest({"from": gov})

    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == providerA.totalDebt()
    util.stateOfStrat("harvest at 5000", rebalancer, providerA, providerB)

    util.simulate_2_sided_trades(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)

    vaultA.updateStrategyDebtRatio(providerA.address, 10_000, {"from": gov})
    chain.sleep(1)

    providerA.harvest({"from": gov})
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == providerA.totalDebt()
    util.stateOfStrat("harvest at 10000", rebalancer, providerA, providerB)

    util.simulate_2_sided_trades(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)

    vaultA.updateStrategyDebtRatio(providerA.address, 5_000, {"from": gov})
    chain.sleep(1)
    providerA.harvest()
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == providerA.totalDebt()
    util.stateOfStrat("harvest at 5000", rebalancer, providerA, providerB)

    util.simulate_2_sided_trades(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)

    vaultA.updateStrategyDebtRatio(providerA.address, 0, {"from": gov})
    chain.sleep(1)
    providerA.harvest()

    # exiting everything out should leave only seed amount which will always be kept in the pool
    assert rebalancer.balanceOfBpt() == rebalancer.seedBptAmount()

    # the estimatedTotalAssets of adapterA should now be the seed amount for A
    assert pytest.approx(providerA.estimatedTotalAssets(), rel=RELATIVE_APPROX) == rebalancer.pooledBalanceA()
    util.stateOfStrat("harvest at 0", rebalancer, providerA, providerB)
