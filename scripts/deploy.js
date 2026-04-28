const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const balance = await deployer.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "ETH");

  const PerpifyReopen = await hre.ethers.getContractFactory("PerpifyReopen");
  const contract = await PerpifyReopen.deploy();
  await contract.waitForDeployment();

  const address = await contract.getAddress();
  console.log("PerpifyReopen deployed to:", address);
  console.log("BaseScan:", `https://sepolia.basescan.org/address/${address}`);

  // Optional: fund the shield
  // const tx = await contract.fundShield({ value: hre.ethers.parseEther("0.01") });
  // await tx.wait();
  // console.log("Shield funded with 0.01 ETH");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
