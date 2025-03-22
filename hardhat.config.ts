import {HardhatUserConfig} from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import * as dotenv from 'dotenv';

dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    ],
  },
  defaultNetwork: 'baseSepolia', // Changed default to Base Sepolia
  networks: {
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
      base: process.env.BASESCAN_API_KEY ?? '', // Add your Basescan API key in .env
      baseSepolia: process.env.BASESCAN_API_KEY ?? '', // Same API key for both Base networks
    },
    customChains: [
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