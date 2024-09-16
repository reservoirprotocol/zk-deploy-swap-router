import { deployContract } from "./utils";
import { DeploymentType } from "zksync-ethers/build/types";

const salt = "0x0000000000000000000000000000000000000000000000000000000000000000";

const PERMIT2 = "0x7d174F25ADcd4157EcB5B3448fEC909AeCB70033"
const SOLVER = "0xf70da97812CB96acDF810712Aa562db8dfA3dbEF"

export default async function () {
  const multicallerAddress = await deployMulticaller();
  const routerAddress = await deployErc20Router(PERMIT2, multicallerAddress);
  await deployApprovalProxy(routerAddress);
  await deployRelayReceiver();
}

const deployMulticaller = async () => {
  const multicaller = await deployContract(
    "Multicaller",
    "create2" as DeploymentType,
    [], // constructorArguments (empty array if there are no constructor arguments)
    {}, // options (empty object if no options are needed)
    {
    customData: {
    salt: salt
    }}
  );

  const multicallerAddress = await multicaller.getAddress();

  return multicallerAddress;
}

const deployApprovalProxy = async (erc20Router: string) => {
  const approvalProxy = await deployContract(
    "ApprovalProxy",
    "create2" as DeploymentType,
    [], // constructorArguments (empty array if there are no constructor arguments)
    {}, // options (empty object if no options are needed)
    {
      customData: {
      salt: salt
    }}
  );

  const approvalProxyAddress = await approvalProxy.getAddress();

  return approvalProxyAddress;
}

const deployErc20Router = async (permit2: string, multicaller: string) => {
  const erc20Router = await deployContract(
    "ERC20Router",
    "create2" as DeploymentType,
    [permit2, multicaller], // constructorArguments (empty array if there are no constructor arguments)
    {}, // options (empty object if no options are needed)
    {
      customData: {
      salt: salt
    }}
  );

  const erc20RouterAddress = await erc20Router.getAddress();

  return erc20RouterAddress;
}

const deployRelayReceiver = async () => {
  const relayReceiver = await deployContract(
    "RelayReceiver",
    "create2" as DeploymentType,
    [SOLVER], // constructorArguments (empty array if there are no constructor arguments)
    {}, // options (empty object if no options are needed)
    {
      customData: {
      salt: salt
    }}
  );

  const relayReceiverAddress = await relayReceiver.getAddress();

  return relayReceiverAddress;
}

