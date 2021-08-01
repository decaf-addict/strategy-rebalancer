import brownie
from brownie import Contract
import pytest
import util


def test_airdrops(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer,
                         user, pool, gov, setup, rando, transferToRando, chain, testSetup, reward, reward_whale,
                         whaleA, whaleB):
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

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultA.pricePerShare()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.stateOfStrat("harvest after swap", rebalancer, providerA, providerB)

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB

    # airdrops
    tokenA.transfer(pool, 3 * 1e18, {'from': whaleA})
    tokenB.transfer(pool, 3 * 1e18, {'from': whaleB})

    tokenA.transfer(rebalancer, 3 * 1e18, {'from': whaleA})
    tokenB.transfer(rebalancer, 3 * 1e18, {'from': whaleB})

    tokenA.transfer(providerA, 3 * 1e18, {'from': whaleA})
    tokenB.transfer(providerB, 3 * 1e18, {'from': whaleB})

    util.stateOfStrat("after airdrop", rebalancer, providerA, providerB)

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultA.pricePerShare()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.stateOfStrat("harvest after airdrop", rebalancer, providerA, providerB)

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB

