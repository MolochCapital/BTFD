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
    base: {
      url: 'https://mainnet.base.org', // Base mainnet RPC
      accounts: [process.env.ACCOUNT_PRIVATE_KEY ?? ''],
    },
    baseSepolia: {
      url: 'https://sepolia.base.org', // Base Sepolia testnet RPC
      accounts: [process.env.ACCOUNT_PRIVATE_KEY ?? ''],
    },
  },
  etherscan: {
    apiKey: {
      mantle: process.env.API_KEY ?? '',
      mantleSepolia: process.env.API_KEY ?? '',
      base: process.env.BASESCAN_API_KEY ?? '', // Add your Basescan API key in .env
      baseSepolia: process.env.BASESCAN_API_KEY ?? '', // Same API key for both Base networks
    },
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
      {
        network: 'base',
        chainId: 8453,
        urls: {
          apiURL: 'https://api.basescan.org/api',
          browserURL: 'https://basescan.org',
        },
      },
      {
        network: 'baseSepolia',
        chainId: 84532,
        urls: {
          apiURL: 'https://api-sepolia.basescan.org/api',
          browserURL: 'https://sepolia.basescan.org',
        },
      },
    ],
  },
};
export default config;