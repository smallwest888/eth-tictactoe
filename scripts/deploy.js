const { ethers } = require("hardhat");

async function main() {
  const Game = await ethers.getContractFactory("Game");
  const game = await Game.deploy();
  await game.waitForDeployment();
  console.log("Game deployed at:", game.target);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
