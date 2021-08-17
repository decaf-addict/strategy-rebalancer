from brownie import JointProvider, accounts, config, network, project, web3

def main():
    with open('./JointProviderFlat.sol', 'w') as f:
        f.write(JointProvider.get_verification_info()['flattened_source'])