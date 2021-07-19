import brownie
from brownie import Contract
import pytest
import util


def test_trigger(gov, vaultA, vaultB, providerA, providerB, tokenA, tokenB, user, amountA, amountB, crv, crv_whale,
                 setup, testSetup, chain, rebalancer, pool, transferToRando, rando):
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    chain.sleep(3600)
    chain.mine(1)

    providerA.tendTrigger(0)
    providerB.tendTrigger(0)

    chain.sleep(3600)
    chain.mine(1)

    assert providerA.harvestTrigger(0) == True
    assert providerB.harvestTrigger(0) == True

    util.simulate_2_sided_trades(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)

    assert providerA.harvestTrigger(0) == True
    assert providerB.harvestTrigger(0) == True

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    util.simulate_1_sided_trade(rebalancer, tokenA, tokenB, providerA, providerB, pool, rando)

    assert providerA.harvestTrigger(0) == False
    assert providerB.harvestTrigger(0) == False
