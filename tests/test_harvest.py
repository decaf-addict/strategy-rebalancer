import brownie
from brownie import Contract
import pytest
import util


def test_harvest_rebalance(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user,
                           pool,
                           gov, setup, chain, testSetup):
    beforeA = pool.getDenormalizedWeight(tokenA)
    beforeB = pool.getDenormalizedWeight(tokenB)
    beforeTotal = pool.getTotalDenormalizedWeight()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    # either adapterA or adapterB tend will trigger a rebalance
    providerA.tend()

    afterA = pool.getDenormalizedWeight(tokenA)
    afterB = pool.getDenormalizedWeight(tokenB)
    afterTotal = pool.getTotalDenormalizedWeight()

    util.stateOfStrat("after tend", rebalancer, providerA, providerB)

    assert beforeA != afterA
    assert beforeB != afterB
    assert beforeTotal == afterTotal


def test_profitable_harvest(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer,
                            user, pool, gov, setup, rando, transferToRando, chain, testSetup, reward, reward_whale):
    beforeHarvestA = pool.getDenormalizedWeight(tokenA)
    beforeHarvestB = pool.getDenormalizedWeight(tokenB)
    beforeHarvestTotal = pool.getTotalDenormalizedWeight()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    afterHarvestA = pool.getDenormalizedWeight(tokenA)
    afterHarvestB = pool.getDenormalizedWeight(tokenB)
    afterHarvestTotal = pool.getTotalDenormalizedWeight()
    assert beforeHarvestA != afterHarvestA
    assert beforeHarvestB != afterHarvestB
    assert beforeHarvestTotal == afterHarvestTotal

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
