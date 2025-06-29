import fs from "fs";
import readline from "readline";
import path from "path";
import dotenv from "dotenv";
import ora from "ora";
import { Command } from "commander";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

// === Constants ==================================================================================

dotenv.config();

const DEFAULT_RPC_URLS = {
    sepolia: "https://eth-sepolia.g.alchemy.com/v2/",
    mainnet: "https://eth-mainnet.g.alchemy.com/v2/",
    anvil: "http://localhost:8545"
};

const getDeploymentsFilename = (network: string) => `scripts/deployments-${network}.json`;

// Contract deployment order based on dependencies
const DEPLOYMENT_ORDER = [
    "ProofRegistry",
    "MerkleManager",
    "MerkleStateManager",
    "ZeroXBridgeL1"
];

// === Types ======================================================================================

interface DeploymentConfig {
    network?: string;
    owner?: string;
    rpcUrl?: string;
}

interface DeployedContract {
    address: string;
    deploymentTx: string;
    timestamp: number;
    network: string;
}

interface DeploymentState {
    [contractName: string]: DeployedContract;
}

// === Utility Functions ==========================================================================

/**
 * Asks the user a question and returns the answer.
 */
function ask(question: string, type?: "int" | "bool"): Promise<string | number | boolean | undefined> {
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });

    return new Promise((resolve, reject) => {
        rl.question(question, (input) => {
            if (type === "int" && input) {
                const parsed = parseInt(input.trim());
                if (isNaN(parsed)) {
                    reject("Invalid input");
                }
                resolve(parsed);
            } else if (type === "bool") {
                if (!input) {
                    resolve(undefined);
                } else {
                    switch (input.trim()) {
                        case "y":
                        case "Y":
                        case "true":
                        case "True":
                            resolve(true);
                            break;
                        case "n":
                        case "N":
                        case "false":
                        case "False":
                            resolve(false);
                            break;
                        default:
                            reject("Invalid input");
                            break;
                    }
                }
            } else {
                resolve(input.trim() || undefined);
            }
            rl.close();
        });
    });
}

/**
 * Load deployment state
 */
function loadDeploymentState(network: string): DeploymentState {
    const deploymentsFilename = getDeploymentsFilename(network);
    if (!fs.existsSync(deploymentsFilename)) {
        return {};
    }
    try {
        return JSON.parse(fs.readFileSync(deploymentsFilename).toString());
    } catch {
        return {};
    }
}

/**
 * Save deployment state
 */
function saveDeploymentState(state: DeploymentState, network: string): void {
    const deploymentsFilename = getDeploymentsFilename(network);
    // Ensure directory exists
    const dir = path.dirname(deploymentsFilename);
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }

    fs.writeFileSync(deploymentsFilename, JSON.stringify(state, null, 2));
}

// === Configuration Functions ===================================================================

async function getPrivateKey(): Promise<string> {
    const privateKey = process.env.PRIVATE_KEY;
    if (!privateKey) {
        throw new Error("PRIVATE_KEY environment variable must be set");
    }
    return privateKey;
}

async function getRpcUrl(config: DeploymentConfig, network: string): Promise<void> {
    // For anvil, use default local URL
    if (network === 'anvil') {
        config.rpcUrl = DEFAULT_RPC_URLS.anvil;
        return;
    }

    // For mainnet/testnet, check Alchemy API key
    const alchemyApiKey = process.env.ALCHEMY_API_KEY;
    if (!alchemyApiKey) {
        throw new Error("ALCHEMY_API_KEY environment variable must be set for mainnet/testnet deployments");
    }

    // Construct RPC URL with API key
    const baseUrl = DEFAULT_RPC_URLS[network as keyof typeof DEFAULT_RPC_URLS];
    config.rpcUrl = `${baseUrl}${alchemyApiKey}`;
}

async function getOwnerAddress(config: DeploymentConfig): Promise<void> {
    if (!config.owner) {
        config.owner = process.env.OWNER_ADDRESS;
    }
    if (!config.owner) {
        config.owner = await ask("Enter owner address: ") as string;
    }
    if (!config.owner) {
        throw new Error("Owner address must be provided");
    }
}

// === Deployment Functions ======================================================================

/**
 * Read deployment information from run-latest.json
 */
async function readLatestDeployment(contractName: string, network: string): Promise<{ address: string; deploymentTx: string }> {
    const networkId = network === 'sepolia' ? '11155111' : 
                     network === 'mainnet' ? '1' : 
                     '31337'; // anvil
    
    const latestRunPath = `broadcast/${contractName}.s.sol/${networkId}/run-latest.json`;
    
    if (!fs.existsSync(latestRunPath)) {
        throw new Error(`Latest deployment file not found: ${latestRunPath}`);
    }
    
    const deployData = JSON.parse(fs.readFileSync(latestRunPath, 'utf8'));
    const transaction = deployData.transactions[0];
    
    if (!transaction?.contractAddress || !transaction?.hash) {
        throw new Error(`Invalid deployment data in ${latestRunPath}`);
    }
    
    return {
        address: transaction.contractAddress,
        deploymentTx: transaction.hash
    };
}

/**
 * Deploy a contract using Foundry script
 */
async function deployContract(
    contractName: string,
    network: string,
    config: DeploymentConfig
): Promise<{ address: string; deploymentTx: string }> {
    const spinner = ora(`Deploying ${contractName}...`).start();
    
    try {
        // Run forge script
        const scriptPath = `scripts/contracts/${contractName}.s.sol`;
        
        // Build the command
        let forgeCommand = `forge script ${scriptPath} --rpc-url ${config.rpcUrl} --broadcast --verify`;
        
        // For ZeroXBridgeL1, check and pass ProofRegistry address
        if (contractName === "ZeroXBridgeL1") {
            const deploymentState = loadDeploymentState(network);
            const proofRegistry = deploymentState["ProofRegistry"];
            
            if (!proofRegistry?.address) {
                spinner.fail("ProofRegistry address not found in deployments. Deploy ProofRegistry first.");
                throw new Error("ProofRegistry must be deployed before ZeroXBridgeL1");
            }
            
            forgeCommand = `PROOF_REGISTRY=${proofRegistry.address} ${forgeCommand}`;
        }

        // Execute the deployment
        await execAsync(forgeCommand);

        // Read deployment information from run-latest.json
        const deploymentInfo = await readLatestDeployment(contractName, network);

        spinner.succeed(`${contractName} deployed at: ${deploymentInfo.address}`);
        
        return deploymentInfo;
        
    } catch (error: any) {
        spinner.fail(`${contractName} deployment failed!`);
        console.error(error.toString());
        throw error;
    }
}

// === Main Deployment Orchestration =============================================================

/**
 * Deploy all contracts in the correct order
 */
async function deployAllContracts(config: DeploymentConfig): Promise<void> {
    console.log(`\n🚀 Starting ZeroXBridge L1 deployment on ${config.network}...\n`);

    // Load existing deployment state for this network
    const deploymentState = loadDeploymentState(config.network!);

    // Deploy contracts in dependency order
    for (const contractName of DEPLOYMENT_ORDER) {
        if (deploymentState[contractName]) {
            console.log(`${contractName} already deployed at: ${deploymentState[contractName].address}`);
            continue;
        }

        const { address, deploymentTx } = await deployContract(
            contractName, 
            config.network!, 
            config
        );
        
        deploymentState[contractName] = {
            address,
            deploymentTx,
            timestamp: Date.now(),
            network: config.network!
        };
        
        saveDeploymentState(deploymentState, config.network!);
    }

    // Final deployment summary
    console.log("\n✅ Deployment completed successfully!\n");
    console.log("📋 Deployed Contracts:");
    console.log("=======================");
    
    for (const [contractName, deployment] of Object.entries(deploymentState)) {
        console.log(`${contractName}:`);
        console.log(`  Address: ${deployment.address}`);
        console.log(`  Deploy Tx: ${deployment.deploymentTx}`);
        console.log();
    }

    const deploymentsFilename = getDeploymentsFilename(config.network!);
    console.log(`💾 Deployment state saved to: ${deploymentsFilename}`);
}

/**
 * Main deployment function for testnet
 */
async function deploymentTestnet(config: DeploymentConfig): Promise<void> {
    // Set network to sepolia for testnet
    config.network = "sepolia";

    // Check for required environment variables first
    if (!process.env.ALCHEMY_API_KEY) {
        console.log("\n⚠️  ALCHEMY_API_KEY not found in environment!");
        console.log("Please add your Alchemy API key to the .env file:");
        console.log("ALCHEMY_API_KEY=your_api_key_here\n");
        throw new Error("Missing ALCHEMY_API_KEY in environment");
    }

    if (!process.env.PRIVATE_KEY) {
        console.log("\n⚠️  PRIVATE_KEY not found in environment!");
        console.log("Please add your private key to the .env file:");
        console.log("PRIVATE_KEY=your_private_key_here\n");
        throw new Error("Missing PRIVATE_KEY in environment");
    }

    await getRpcUrl(config, config.network);
    await getOwnerAddress(config);
    
    await deployAllContracts(config);
}

/**
 * Main deployment function for mainnet
 */
async function deploymentMainnet(config: DeploymentConfig): Promise<void> {
    console.log("⚠️  WARNING: You are deploying to MAINNET!");
    
    // Check for required environment variables first
    if (!process.env.ALCHEMY_API_KEY) {
        console.log("\n⚠️  ALCHEMY_API_KEY not found in environment!");
        console.log("Please add your Alchemy API key to the .env file:");
        console.log("ALCHEMY_API_KEY=your_api_key_here\n");
        throw new Error("Missing ALCHEMY_API_KEY in environment");
    }

    if (!process.env.PRIVATE_KEY) {
        console.log("\n⚠️  PRIVATE_KEY not found in environment!");
        console.log("Please add your private key to the .env file:");
        console.log("PRIVATE_KEY=your_private_key_here\n");
        throw new Error("Missing PRIVATE_KEY in environment");
    }

    const confirm = await ask("Are you sure you want to continue? [y/N]: ", "bool");
    
    if (!confirm) {
        console.log("Deployment cancelled.");
        return;
    }

    // Set network to mainnet
    config.network = "mainnet";

    await getRpcUrl(config, config.network);
    await getOwnerAddress(config);
    
    await deployAllContracts(config);
}

/**
 * Deploy to local anvil
 */
async function deploymentAnvil(config: DeploymentConfig): Promise<void> {
    // Set network and default anvil values
    config.network = "anvil";
    await getPrivateKey();
    await getRpcUrl(config, config.network);
    await getOwnerAddress(config);
    
    await deployAllContracts(config);
}

// === CLI Interface ==============================================================================

async function main(): Promise<void> {
    const program = new Command();

    program
        .name("deploy-l1")
        .description("A CLI interface for deploying ZeroXBridge L1 contracts.");

    program
        .command("deploy")
        .description("Interactively deploys the ZeroXBridge L1 contracts on Ethereum mainnet.")
        .action(async () => {
            let config = {};
            await deploymentMainnet(config);
        });

    program
        .command("deploy-testnet")
        .description("Interactively deploys the ZeroXBridge L1 contracts on Ethereum testnet (Sepolia).")
        .action(async () => {
            let config = {};
            await deploymentTestnet(config);
        });

    program
        .command("deploy-anvil")
        .description("Deploys the ZeroXBridge L1 contracts on local Anvil network.")
        .action(async () => {
            let config = {};
            await deploymentAnvil(config);
        });

    await program.parseAsync();
}

// Execute if this file is run directly
if (require.main === module) {
    main().then(() => process.exit(0)).catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    });
}