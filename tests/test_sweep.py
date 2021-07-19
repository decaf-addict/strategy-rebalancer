import brownie
from brownie import Contract
import pytest


def test_sweep(gov, vaultA, vaultB, providerA, providerB, tokenA, tokenB, user, amountA, amountB, crv, crv_whale):
    # Strategy want token doesn't work
    tokenA.transfer(providerA, amountA, {"from": user})
    assert tokenA.address == providerA.want()
    assert tokenA.balanceOf(providerA) > 0
    with brownie.reverts("!want"):
        providerA.sweep(tokenA, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        providerA.sweep(vaultA.address, {"from": gov})

    tokenB.transfer(providerB, amountB, {"from": user})
    assert tokenB.address == providerB.want()
    assert tokenB.balanceOf(providerB) > 0
    with brownie.reverts("!want"):
        providerB.sweep(tokenB, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        providerB.sweep(vaultB.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.protectedToken(), {"from": gov})

    before_balance = crv.balanceOf(gov)
    crv.transfer(providerA, 1000 * 1e18, {"from": crv_whale})
    crv.transfer(providerB, 1000 * 1e18, {"from": crv_whale})

    assert crv.address != providerA.want()
    assert crv.address != providerB.want()
    providerA.sweep(crv, {"from": gov})
    providerB.sweep(crv, {"from": gov})
    assert crv.balanceOf(gov) == (1000 * 1e18 + before_balance) * 2

