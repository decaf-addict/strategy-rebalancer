import brownie
from brownie import Contract
import pytest
import util


def test_triggers(providerATestOracle, providerBTestOracle, tokenA, tokenB, amountA, amountB, vaultA, vaultB,
                  rebalancerTestOracle, testOracleA, testOracleB, oracleA, oracleB,
                  user, gov, setupTestOracle, rando, transferToRando, testSetup, reward, reward_whale):
    testOracleA.setPrice(oracleA.latestAnswer(), {'from': rando})
    testOracleB.setPrice(oracleB.latestAnswer(), {'from': rando})

    providerATestOracle.harvest({"from": gov})
    providerBTestOracle.harvest({"from": gov})

    # changes too small to require tend = ~0.4% <(swap fee * 2)
    testOracleA.setPrice(oracleA.latestAnswer() * .998, {'from': rando})
    testOracleB.setPrice(oracleB.latestAnswer() * 1.002, {'from': rando})

    assert providerATestOracle.tendTrigger(0) == False
    assert providerBTestOracle.tendTrigger(0) == False

    # changes large enough to require tend >(swap fee * 2)
    testOracleA.setPrice(oracleA.latestAnswer() * .95, {'from': rando})
    testOracleB.setPrice(oracleB.latestAnswer() * 1.01, {'from': rando})

    assert providerATestOracle.tendTrigger(0) == True
    assert providerBTestOracle.tendTrigger(0) == True

    # 10%
    rebalancerTestOracle.setSwapFee(.1 * 1e18, {'from': gov})

    assert providerATestOracle.tendTrigger(0) == False
    assert providerBTestOracle.tendTrigger(0) == False

    # price drops to something that will cause weights to hit the boundary. Test that public swap disables.
    testOracleB.setPrice(oracleB.latestAnswer() * 0.001, {'from': rando})
    assert providerBTestOracle.tendTrigger(0) == True

    util.stateOfStrat("skewed", rebalancerTestOracle, providerATestOracle, providerBTestOracle)

    providerBTestOracle.tend({'from': gov})

    assert rebalancerTestOracle.getPublicSwap() == False
    assert providerATestOracle.tendTrigger(0) == False
    assert providerBTestOracle.tendTrigger(0) == False

    # when vault managers do some debt adjustment or when price goes back up to a healthy weight balance,
    # the next tend will enable swap again. In this case we simulate price going back up.
    testOracleB.setPrice(oracleB.latestAnswer(), {'from': rando})
    assert providerBTestOracle.tendTrigger(0) == True
    providerBTestOracle.tend({'from': gov})

    util.stateOfStrat("normal", rebalancerTestOracle, providerATestOracle, providerBTestOracle)
