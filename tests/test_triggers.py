import brownie
from brownie import Contract
import pytest
import util


def test_triggers(providerATestOracle, providerBTestOracle, tokenA, tokenB, amountA, amountB, vaultA, vaultB,
                  rebalancerTestOracle, testOracleA, testOracleB, oracleA, oracleB,
                  user, gov, setupTestOracle, rando, transferToRando, chain, testSetup, reward, reward_whale):
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
    testOracleA.setPrice(oracleA.latestAnswer() * .99, {'from': rando})
    testOracleB.setPrice(oracleB.latestAnswer() * 1.01, {'from': rando})

    assert providerATestOracle.tendTrigger(0) == True
    assert providerBTestOracle.tendTrigger(0) == True

    rebalancerTestOracle.setSwapFee(.015 * 1e18, {'from': gov})

    assert providerATestOracle.tendTrigger(0) == False
    assert providerBTestOracle.tendTrigger(0) == False


