require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: "0.8.27",
  networks: {
    // 连接本地私链（Geth/Hardhat 节点）
    local: {
      url: "http://127.0.0.1:8545",
    },
  },
};
