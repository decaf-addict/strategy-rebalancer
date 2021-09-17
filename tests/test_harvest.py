import brownie
from brownie import Contract
import pytest
import util


def test_harvest_rebalance(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user,
                           gov, setup, chain, testSetup):
    beforeA = rebalancer.currentWeightA()
    beforeB = rebalancer.currentWeightB()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    # either adapterA or adapterB tend will trigger a rebalance
    providerA.tend()

    afterA = rebalancer.currentWeightA()
    afterB = rebalancer.currentWeightB()

    util.stateOfStrat("after tend", rebalancer, providerA, providerB)

    assert beforeA != afterA
    assert beforeB != afterB

#
# def test_profitable_harvest(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer,
#                             user, gov, setup, rando, transferToRando, chain, testSetup, reward, reward_whale):
#     beforeHarvestA = rebalancer.currentWeightA()
#     beforeHarvestB = rebalancer.currentWeightB()
#
#     providerA.harvest({"from": gov})
#     providerB.harvest({"from": gov})
#
#     afterHarvestA = rebalancer.currentWeightA()
#     afterHarvestB = rebalancer.currentWeightB()
#     assert beforeHarvestA != afterHarvestA
#     assert beforeHarvestB != afterHarvestB
#
#     util.simulate_2_sided_trades(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)
#     util.simulate_bal_reward(rebalancer, reward, reward_whale)
#     util.stateOfStrat("after bal reward", rebalancer, providerA, providerB)
#
#     ppsBeforeA = vaultA.pricePerShare()
#     ppsBeforeB = vaultB.pricePerShare()
#
#     providerA.harvest({"from": gov})
#     util.stateOfStrat("harvestA after swap", rebalancer, providerA, providerB)
#     providerB.harvest({"from": gov})
#     util.stateOfStrat("harvestB after swap", rebalancer, providerA, providerB)
#
#     chain.sleep(3600)
#     chain.mine(1)
#
#     assert vaultA.pricePerShare() > ppsBeforeA
#     assert vaultB.pricePerShare() > ppsBeforeB
