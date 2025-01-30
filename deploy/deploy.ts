import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployer } = await hre.getNamedAccounts();
  const { deploy } = hre.deployments;

  const deployed = await deploy("MockConfidentialERC20", {
    from: deployer,
    args: ["MockERC20", "ME2"],
    log: true,
  });

  console.log(`MockConfidentialERC20 contract: `, deployed.address);
};
export default func;
func.id = "deploy_confidentialERC20"; // id required to prevent reexecution
func.tags = ["MockConfidentialERC20"];
