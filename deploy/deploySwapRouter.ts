import { deployContract } from "./utils";
import { DeploymentType } from "zksync-ethers/build/types";

const salt = "0x0000000000000000000000000000000000000000000000000000000000000000";

export default async function () {
    await deploySwapRouter();
}

const deploySwapRouter = async () => {
    await deployContract(
        "SwapRouter02",
        "create2" as DeploymentType,
        ["0x1B4427e212475B12e62f0f142b8AfEf3BC18B559", // v2 factory
            "0xA1160e73B63F322ae88cC2d8E700833e71D0b2a1", // v3 factory
            "0x5b15468dFD83cF9192082d4510034c9431bb05eB", // position manager
            "0xAc98B49576B1C892ba6BFae08fE1BB0d80Cf599c"], // weth
        {}, // options (empty object if no options are needed)
        {
            customData: {
                salt: salt
            }
        }
    );
}