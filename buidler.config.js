usePlugin("@nomiclabs/buidler-truffle5");

require("./scripts/moloch-tasks");
require("./scripts/pool-tasks");

const INFURA_API_KEY =
  "https://mainnet.infura.io/v3/497b4b7a120a49e288702128beeb7e8d";
const MAINNET_PRIVATE_KEY =
  "7B017931EA2F7DEDD2FADE6BFA2A9AD7DC4EA361C34E286BFF05ADA5C6CA20BB";
const ROPSTEN_PRIVATE_KEY = "";

module.exports = {
  networks: {
    develop: {
      deployedContracts: {
        moloch: "",
        pool: "",
      },
    },
    ropsten: {
      url: `https://ropsten.infura.io/v3/${INFURA_API_KEY}`,
      accounts: [ROPSTEN_PRIVATE_KEY],
      deployedContracts: {
        moloch: "",
        pool: "",
      },
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${INFURA_API_KEY}`,
      accounts: [MAINNET_PRIVATE_KEY],
      deployedContracts: {
        moloch: "0x1fd169A4f5c59ACf79d0Fd5d91D1201EF1Bce9f1", // The original Moloch
        pool: "",
      },
    },
    coverage: {
      url: "http://localhost:7545",
    },
  },
  solc: {
    version: "0.5.3",
    evmVersion: "byzantium",
  },
};
