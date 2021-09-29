from brownie import Contract, accounts, config, network, project, web3, accounts


def main():
    sms = accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)

    rebalancer = Contract("0xC0685ED3ACf4Ff688298240825128425287feEAD")
    providerYFI = Contract("0x0265ED0ffcB845EEc463bC1aD6fB412Cce6b9aE9")
    providerWETH = Contract("0x579E5d43bA85c26c6e5A8c20b52a01E3318831aE")

    vaultYFI = Contract(providerYFI.vault())
    vaultWETH = Contract(providerWETH.vault())

    providerYFI.setRebalancer(rebalancer, {'from': sms})
    providerWETH.setRebalancer(rebalancer, {'from': sms})

    vaultYFI.addStrategy(providerYFI, 0, 0, 2 ** 256 - 1, 1_000, {"from": sms})
    vaultWETH.addStrategy(providerWETH, 0, 0, 2 ** 256 - 1, 1_000, {"from": sms})
