// scripts/deploy.js — Hardhat deploy for PerpifyReopenPyth on Base mainnet.
//
// Usage:
//   npx hardhat run scripts/deploy.js --network base
//
// Required hardhat.config.js excerpt:
//   networks: {
//     base: {
//       url: 'https://mainnet.base.org',
//       accounts: [process.env.DEPLOYER_PRIVATE_KEY],
//     },
//   }
//
// Pre-flight checklist (do these before running):
//   1. Fund deployer with 0.005 ETH on Base mainnet (≈ $10 buffer; deploy is cheap).
//   2. Set DEPLOYER_PRIVATE_KEY in .env (NEVER commit).
//   3. Confirm the addresses below are correct against the live Pyth docs.

const PYTH_BASE_MAINNET = '0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a';
const SPY_FEED_ID       = '0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5';

// Loss buffer for the demo, in wei. Doesn't affect anything in USD-space — the
// contract's USD math is independent — but it sets the scale used for the
// "buffer used %" metric. 0.05 ETH buffer mirrors the 5% shield used in the
// 10,000-scenario simulation at $5M OI.
const LOSS_BUFFER_WEI = 50_000_000_000_000_000n; // 0.05 ETH

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const balance = await hre.ethers.provider.getBalance(deployer.address);

  console.log('Deployer:', deployer.address);
  console.log('Balance: ', hre.ethers.formatEther(balance), 'ETH');

  if (balance < 1_000_000_000_000_000n) {
    throw new Error('Deployer balance below 0.001 ETH — fund the wallet first.');
  }

  const Factory = await hre.ethers.getContractFactory('PerpifyReopenPyth');

  console.log('Deploying PerpifyReopenPyth with:');
  console.log('  Pyth:          ', PYTH_BASE_MAINNET);
  console.log('  SPY feed ID:   ', SPY_FEED_ID);
  console.log('  Loss buffer:   ', LOSS_BUFFER_WEI.toString(), 'wei (0.05 ETH)');

  const c = await Factory.deploy(PYTH_BASE_MAINNET, SPY_FEED_ID, LOSS_BUFFER_WEI, {
    value: LOSS_BUFFER_WEI,  // fund the loss buffer at deploy
  });
  await c.waitForDeployment();

  const addr = await c.getAddress();
  console.log('\n✓ PerpifyReopenPyth deployed at:', addr);
  console.log('  Basescan:  https://basescan.org/address/' + addr);
  console.log('\nNext: copy this address into your frontend config:');
  console.log(`  const CONTRACT_ADDRESS = '${addr}';`);
}

main().catch(e => { console.error(e); process.exit(1); });
