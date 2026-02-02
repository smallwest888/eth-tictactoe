const { ethers } = require("hardhat");

// Dedicated Dev account (not Hardhat #0/#1); starts with 0 balance on local node. Same as frontend DEV_ACCOUNT_PK.
const DEV_ACCOUNT_PK = "0x00000000000000000000000000000000000000000000000000000000000000ff";

async function main() {
  const TicTacToe = await ethers.getContractFactory("TicTacToe");
  const dev = process.env.DEV_ADDRESS || (() => {
    const w = new ethers.Wallet(DEV_ACCOUNT_PK);
    return w.address;
  })();
  const ttt = await TicTacToe.deploy(dev);
  await ttt.waitForDeployment();
  console.log("TicTacToe deployed at:", ttt.target);
  console.log("Dev address (fee recipient, separate from deployer):", dev);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
