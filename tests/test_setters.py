import pytest
import util
import brownie


def test_set_rebalancer(providerA, providerB, rebalancer, gov, setup):
    providerA.setRebalancer(rebalancer, {'from': gov})
    providerB.setRebalancer(rebalancer, {'from': gov})
    # just make sure there's no reverts


def test_set_reward(providerA, providerB, tokenA, tokenB, amountA, amountB, vaultA, vaultB, rebalancer, user, gov,
                    setup, RELATIVE_APPROX, testSetup, crv, crv_whale, chain):
    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    assert providerA.balanceOfWant() == 0
    assert providerB.balanceOfWant() == 0

    rebalancer.setReward(crv, {'from': gov})
    crv.transfer(rebalancer, 10000 * 1e18, {'from': crv_whale})

    ppsBeforeA = vaultA.pricePerShare()
    ppsBeforeB = vaultA.pricePerShare()

    providerA.harvest({"from": gov})
    providerB.harvest({"from": gov})

    chain.sleep(3600)
    chain.mine(1)

    assert vaultA.pricePerShare() > ppsBeforeA
    assert vaultB.pricePerShare() > ppsBeforeB
