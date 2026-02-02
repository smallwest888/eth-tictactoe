const { ethers } = require("hardhat");

async function main() {
  const TicTacToe = await ethers.getContractFactory("TicTacToe");
  const dev = process.env.DEV_ADDRESS || ethers.ZeroAddress;
  const ttt = await TicTacToe.deploy(dev);
  await ttt.waitForDeployment();
  console.log("TicTacToe deployed at:", ttt.target);
  console.log("Dev address:", dev === ethers.ZeroAddress ? "deployer (address(0))" : dev);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
