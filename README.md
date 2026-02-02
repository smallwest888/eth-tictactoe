# Local Private Chain Demo & Deployment Guide (TicTacToe Game)

## Prerequisites
- Node: use `/opt/homebrew/opt/node@20/bin` (installed via brew `node@20`).
- Install deps in project root:
  ```bash
  rm -rf node_modules package-lock.json
  npm install
  ```

## Start a local chain (Hardhat node)
Run in project root (keep terminal open):
```bash
npx hardhat node --hostname 127.0.0.1 --port 8545
```
This starts JSON-RPC at http://127.0.0.1:8545 with prefunded test accounts.

## Compile & deploy the contract
In another terminal (same project root):
```bash
# compile
npx hardhat compile
# deploy to local chain
npx hardhat run scripts/deploy.js --network local
```
You'll see the `Game` contract address, e.g.:
```
Game deployed at: 0x5FbDB2315678afecb367f032d93F642f64180aa3
```

## Contract overview (`contracts/Game.sol`)
- `createGame()`: creator becomes `playerX`, stakes ETH to form the prize pool.
- `joinGame(gameId)`: second player joins as `playerO`, must match the stake.
- Manager = deployer; fee 2.5% (`managerFeeBps = 250`).
- `settleGame(gameId, outcome)`: manager-only; `outcome` is `WinX/WinO/Draw`, auto distributes prize and fee.
- Events: `GameCreated`, `GameJoined`, `GameSettled`.

## Quick interaction (Hardhat console)
With local chain running:
```bash
npx hardhat console --network local
```
Example:
```js
const game = await ethers.getContractAt("Game", "<deployed_address>");
const [deployer, user] = await ethers.getSigners();

// Create (X)
await game.connect(deployer).createGame({ value: ethers.parseEther("0.1") });
// Join (O)
await game.connect(user).joinGame(1, { value: ethers.parseEther("0.1") });
// Settle by manager, 3=WinX, 4=WinO, 0=Draw
await game.connect(deployer).settleGame(1, 3);
```

## Frontend demo
- `index.html`: open directly in browser for the local probability demo; on-chain panel is available if you connect to the local RPC and set the correct contract address.

## Troubleshooting
- Cannot connect network: ensure local node at `127.0.0.1:8545` is running.
- Node version unsupported: ensure `node -v` is 18/20 (not 25+).
