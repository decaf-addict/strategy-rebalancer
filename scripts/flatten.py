from brownie import Rebalancer, accounts, config, network, project, web3

def main():
    with open('./RebalancerFlat.sol', 'w') as f:
        f.write(Rebalancer.get_verification_info()['flattened_source'])