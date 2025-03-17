import {HardhatUserConfig} from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import * as dotenv from 'dotenv';

dotenv.config();

const config: HardhatUserConfig = {
  solidity: '0.8.19', // solidity version
  defaultNetwork: 'mantleSepolia', // chosen by default when network isn't specified while running Hardhat
  networks: {
    mantle: {
      url: 'https://rpc.mantle.xyz', // Original mainnet RPC
      accounts: [process.env.ACCOUNT_PRIVATE_KEY ?? ''],
    },
    mantleSepolia: {
      url: 'https://rpc.sepolia.mantle.xyz', // Original Sepolia testnet RPC
      accounts: [process.env.ACCOUNT_PRIVATE_KEY ?? ''],
      gasPrice: 20000000,
    },
  },
  etherscan: {
    apiKey: process.env.API_KEY,
    customChains: [
      {
        network: 'mantle',
        chainId: 5000,
        urls: {
          apiURL: 'https://api.mantlescan.xyz/api',
          browserURL: 'https://mantlescan.xyz',
        },
      },
      {
        network: 'mantleSepolia',
        chainId: 5003,
        urls: {
          apiURL: 'https://api-sepolia.mantlescan.xyz/api',
          browserURL: 'https://sepolia.mantlescan.xyz/',
        },
      },
    ],
  },
};
export default config;