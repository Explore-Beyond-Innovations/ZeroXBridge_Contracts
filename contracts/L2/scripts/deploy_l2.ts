import fs from "fs";
import readline from "readline";
import path from "path";
import dotenv from "dotenv";
import ora from "ora";
import { Command } from "commander";
import { Account, CallData, Contract, RpcProvider, json } from "starknet";

// === Constants ==================================================================================

dotenv.config();

const DEFAULT_RPC_URLS = {
    sepolia: "https://starknet-sepolia.public.blastapi.io/rpc/v0_7",
    mainnet: "https://starknet-mainnet.public.blastapi.io/rpc/v0_7", 
    devnet: "http://127.0.0.1:5050"
};

const getConfigFilename = (network: string) => `scripts/.deploy-config-${network}.json`;
const getDeploymentsFilename = (network: string) => `scripts/deployments-${network}.json`;

// Contract deployment order based on dependencies
const DEPLOYMENT_ORDER = [
    "ProofRegistry",
    "L2Oracle", 
    "xZBERC20",
    "ZeroXBridgeL2"
];

// === Types ======================================================================================

interface DeploymentConfig {
    accountAddress?: string;
    starknetRpcUrl?: string;
    network?: string;
    owner?: string;
    minRate?: string;
    maxRate?: string;
}

interface DeployedContract {
    address: string;
    classHash: string;
    declareTx: string;
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
 * Load configuration from previous deployments
 */
async function loadConfiguration(useConfig: boolean, network: string): Promise<DeploymentConfig> {
    if (!process.env.STARKNET_PRIVATE_KEY) {
        throw new Error("STARKNET_PRIVATE_KEY is not set");
    }

    if (!useConfig) {
        return {};
    }

    const configFilename = getConfigFilename(network);
    let answer = await ask(`Do you want to load configuration from prior runs? [Y/n]: `, "bool");
    const spinner = ora("Configuration Loading").start();
    
    if (answer === undefined) {
        answer = true;
    }

    if (answer) {
        if (!fs.existsSync(configFilename)) {
            spinner.warn("Configuration load requested but no configuration available: continuing");
            return {};
        }
        try {
            const fileContents = JSON.parse(fs.readFileSync(configFilename).toString());
            if (fileContents) {
                spinner.succeed("Configuration loaded");
                return fileContents;
            } else {
                spinner.warn("Unable to parse configuration: deleting and continuing");
                fs.rmSync(configFilename);
                return {};
            }
        } catch {
            spinner.warn("Unable to parse configuration: deleting and continuing");
            fs.rmSync(configFilename);
            return {};
        }
    } else {
        spinner.succeed("Configuration not loaded");
        return {};
    }
}

/**
 * Save configuration for future runs
 */
async function saveConfiguration(config: DeploymentConfig, network: string): Promise<void> {
    const configFilename = getConfigFilename(network);
    const oldData = (() => {
        try {
            return JSON.parse(fs.readFileSync(configFilename).toString());
        } catch {
            return {};
        }
    })();

    // Ensure directory exists
    const dir = path.dirname(configFilename);
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }

    const data = JSON.stringify({ ...oldData, ...config }, null, 2);
    fs.writeFileSync(configFilename, data);
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

async function getAccountAddress(config: DeploymentConfig): Promise<void> {
    if (!config.accountAddress) {
        config.accountAddress = process.env.STARKNET_ACCOUNT_ADDRESS;
    }
    if (!config.accountAddress) {
        config.accountAddress = await ask("Enter your Starknet account address: ") as string;
    }
}

async function getStarknetRpcUrl(config: DeploymentConfig, network: string): Promise<void> {
    if (!config.starknetRpcUrl) {
        config.starknetRpcUrl = process.env.STARKNET_RPC_URL;
    }
    if (!config.starknetRpcUrl) {
        const defaultRpc = DEFAULT_RPC_URLS[network as keyof typeof DEFAULT_RPC_URLS];
        config.starknetRpcUrl = await ask(`Enter Starknet RPC URL: (${defaultRpc}) `) as string;
    }
    if (!config.starknetRpcUrl) {
        config.starknetRpcUrl = DEFAULT_RPC_URLS[network as keyof typeof DEFAULT_RPC_URLS];
    }
}

async function getOwnerAddress(config: DeploymentConfig): Promise<void> {
    if (!config.owner) {
        config.owner = process.env.OWNER_ADDRESS || config.accountAddress;
    }
    if (!config.owner) {
        config.owner = await ask("Enter owner address (default: deployer): ") as string;
    }
    if (!config.owner) {
        config.owner = config.accountAddress;
    }
}

async function getRateParameters(config: DeploymentConfig): Promise<void> {
    if (!config.minRate) {
        config.minRate = process.env.MIN_RATE;
    }
    if (!config.minRate) {
        config.minRate = await ask("Enter minimum rate (default: 1000000000000000000): ") as string;
    }
    if (!config.minRate) {
        config.minRate = "1000000000000000000"; // 1 with 18 decimals
    }

    if (!config.maxRate) {
        config.maxRate = process.env.MAX_RATE;
    }
    if (!config.maxRate) {
        config.maxRate = await ask("Enter maximum rate (default: 2000000000000000000): ") as string;
    }
    if (!config.maxRate) {
        config.maxRate = "2000000000000000000"; // 2 with 18 decimals
    }
}

// === Deployment Functions ======================================================================

/**
 * Declare a contract using Starknet.js (Option 3: Declare separately)
 */
async function declareContract(
    contractName: string,
    account: Account
): Promise<{ classHash: string; declareTx: string }> {
    const spinner = ora(`Declaring ${contractName}...`).start();
    
    try {
        // Read the compiled contract files (both Sierra and CASM)
        const sierraPath = `target/dev/l2_${contractName}.contract_class.json`;
        const casmPath = `target/dev/l2_${contractName}.compiled_contract_class.json`;
        
        if (!fs.existsSync(sierraPath)) {
            throw new Error(`Sierra contract file not found: ${sierraPath}`);
        }
        
        if (!fs.existsSync(casmPath)) {
            throw new Error(`CASM contract file not found: ${casmPath}. Run 'scarb build' to generate CASM files.`);
        }
        
        const sierraContract = json.parse(fs.readFileSync(sierraPath).toString("ascii"));
        const casmContract = json.parse(fs.readFileSync(casmPath).toString("ascii"));
        
        const declareResponse = await account.declare({
            contract: sierraContract,
            casm: casmContract,
        });
        
        // Wait for the declare transaction to be accepted
        await account.waitForTransaction(declareResponse.transaction_hash);
        
        spinner.succeed(`${contractName} declared with class hash: ${declareResponse.class_hash}`);
        
        return {
            classHash: declareResponse.class_hash,
            declareTx: declareResponse.transaction_hash
        };
        
    } catch (error: any) {
        // If contract is already declared, extract class hash from error
        if (error.message.includes("is already declared")) {
            const classHashMatch = error.message.match(/Class with hash (0x[a-fA-F0-9]+) is already declared/);
            if (classHashMatch) {
                const classHash = classHashMatch[1];
                spinner.info(`${contractName} already declared with class hash: ${classHash}`);
                return {
                    classHash: classHash,
                    declareTx: "already_declared"
                };
            }
        }
        spinner.fail(`${contractName} declaration failed!`);
        console.error(error.toString());
        throw error;
    }
}

/**
 * Deploy a contract using Starknet.js
 */
async function deployContract(
    contractName: string,
    classHash: string,
    constructorArgs: any[],
    account: Account,
    network: string
): Promise<{ address: string; deploymentTx: string }> {
    const spinner = ora(`Deploying ${contractName}...`).start();
    
    try {
        // Deploy the contract
        const deployResponse = await account.deployContract({
            classHash: classHash,
            constructorCalldata: constructorArgs,
        });
        
        // Wait for the deployment transaction to be accepted
        await account.waitForTransaction(deployResponse.transaction_hash);
        
        spinner.succeed(`${contractName} deployed at: ${deployResponse.contract_address}`);
        
        return {
            address: deployResponse.contract_address,
            deploymentTx: deployResponse.transaction_hash
        };
        
    } catch (error: any) {
        spinner.fail(`${contractName} deployment failed!`);
        console.error(error.toString());
        throw error;
    }
}

async function declareAndDeploy(
    contractName: string,
    constructorArgs: any[],
    account: Account,
    network: string
): Promise<DeployedContract> {
    // Step 1: Declare the contract
    const { classHash, declareTx } = await declareContract(contractName, account);
    
    // Step 2: Deploy using the class hash
    const { address, deploymentTx } = await deployContract(
        contractName,
        classHash,
        constructorArgs,
        account,
        network
    );
    
    return {
        address,
        classHash,
        declareTx,
        deploymentTx,
        timestamp: Date.now(),
        network
    };
}

// === Specific Contract Deployment Functions ===================================================

/**
 * Deploy ProofRegistry contract
 */
async function deployProofRegistry(
    account: Account,
    network: string,
    deploymentState: DeploymentState
): Promise<void> {
    if (deploymentState.ProofRegistry) {
        console.log(`ProofRegistry already deployed at: ${deploymentState.ProofRegistry.address}`);
        return;
    }

    const deployed = await declareAndDeploy("ProofRegistry", [], account, network);
    deploymentState.ProofRegistry = deployed;
    saveDeploymentState(deploymentState, network);
}

/**
 * Deploy L2Oracle contract
 */
async function deployL2Oracle(
    config: DeploymentConfig,
    account: Account,
    network: string,
    deploymentState: DeploymentState
): Promise<void> {
    if (deploymentState.L2Oracle) {
        console.log(`L2Oracle already deployed at: ${deploymentState.L2Oracle.address}`);
        return;
    }

    const constructorArgs = [config.owner];
    const deployed = await declareAndDeploy("L2Oracle", constructorArgs, account, network);
    deploymentState.L2Oracle = deployed;
    saveDeploymentState(deploymentState, network);
}

/**
 * Deploy xZBERC20 contract
 */
async function deployXZBERC20(
    config: DeploymentConfig,
    account: Account,
    network: string,
    deploymentState: DeploymentState
): Promise<void> {
    if (deploymentState.xZBERC20) {
        console.log(`xZBERC20 already deployed at: ${deploymentState.xZBERC20.address}`);
        return;
    }

    const constructorArgs = [config.owner];
    const deployed = await declareAndDeploy("xZBERC20", constructorArgs, account, network);
    deploymentState.xZBERC20 = deployed;
    saveDeploymentState(deploymentState, network);
}

/**
 * Deploy ZeroXBridgeL2 contract
 */
async function deployZeroXBridgeL2(
    config: DeploymentConfig,
    account: Account,
    network: string,
    deploymentState: DeploymentState
): Promise<void> {
    if (deploymentState.ZeroXBridgeL2) {
        console.log(`ZeroXBridgeL2 already deployed at: ${deploymentState.ZeroXBridgeL2.address}`);
        return;
    }

    // Ensure dependencies are deployed
    if (!deploymentState.ProofRegistry) {
        throw new Error("ProofRegistry must be deployed before ZeroXBridgeL2");
    }
    if (!deploymentState.L2Oracle) {
        throw new Error("L2Oracle must be deployed before ZeroXBridgeL2");
    }
    if (!deploymentState.xZBERC20) {
        throw new Error("xZBERC20 must be deployed before ZeroXBridgeL2");
    }

    const constructorArgs = [
        config.owner,                                 // owner
        deploymentState.xZBERC20.address,             // token
        deploymentState.ProofRegistry.address,        // proof_registry_address
        deploymentState.L2Oracle.address,             // oracle_address
        { low: config.minRate, high: "0" },           // min_rate (u256)
        { low: config.maxRate, high: "0" }            // max_rate (u256)
    ];

    const deployed = await declareAndDeploy("ZeroXBridgeL2", constructorArgs, account, network);
    deploymentState.ZeroXBridgeL2 = deployed;
    saveDeploymentState(deploymentState, network);
}

/**
 * Set up contract relationships after deployment
 */
async function setupContractRelationships(
    account: Account,
    deploymentState: DeploymentState,
    network: string
): Promise<void> {
    const spinner = ora("Setting up contract relationships...").start();

    try {
        // Set bridge address in xZBERC20 contract to allow minting
        if (deploymentState.xZBERC20 && deploymentState.ZeroXBridgeL2) {
            const calldata = CallData.compile([deploymentState.ZeroXBridgeL2.address]);
            const response = await account.execute({
                contractAddress: deploymentState.xZBERC20.address,
                entrypoint: "set_bridge_address",
                calldata: calldata
            });

            await account.waitForTransaction(response.transaction_hash);
            spinner.info("Bridge address set in xZBERC20 contract");
        }

        spinner.succeed("Contract relationships setup completed!");
    } catch (error: any) {
        spinner.fail("Contract relationships setup failed!");
        console.error(error.toString());
        throw error;
    }
}

// === Main Deployment Orchestration =============================================================

/**
 * Deploy all contracts in the correct order
 */
async function deployAllContracts(config: DeploymentConfig): Promise<void> {
    console.log(`\n🚀 Starting ZeroXBridge L2 deployment on ${config.network}...\n`);

    // Setup provider and account
    const provider = new RpcProvider({ nodeUrl: config.starknetRpcUrl! });
    const account = new Account(provider, config.accountAddress!, process.env.STARKNET_PRIVATE_KEY!);

    // Load existing deployment state for this network
    const deploymentState = loadDeploymentState(config.network!);

    // Deploy contracts in dependency order
    for (const contractName of DEPLOYMENT_ORDER) {
        switch (contractName) {
            case "ProofRegistry":
                await deployProofRegistry(account, config.network!, deploymentState);
                break;
            case "L2Oracle":
                await deployL2Oracle(config, account, config.network!, deploymentState);
                break;
            case "xZBERC20":
                await deployXZBERC20(config, account, config.network!, deploymentState);
                break;
            case "ZeroXBridgeL2":
                await deployZeroXBridgeL2(config, account, config.network!, deploymentState);
                break;
            default:
                console.warn(`Unknown contract: ${contractName}`);
        }
    }

    // Setup contract relationships
    await setupContractRelationships(account, deploymentState, config.network!);

    // Final deployment summary
    console.log("\n✅ Deployment completed successfully!\n");
    console.log("📋 Deployed Contracts:");
    console.log("=======================");
    
    for (const [contractName, deployment] of Object.entries(deploymentState)) {
        console.log(`${contractName}:`);
        console.log(`  Address: ${deployment.address}`);
        console.log(`  Class Hash: ${deployment.classHash}`);
        console.log(`  Declare Tx: ${deployment.declareTx}`);
        console.log(`  Deploy Tx: ${deployment.deploymentTx}`);
        console.log();
    }

    const deploymentsFilename = getDeploymentsFilename(config.network!);
    const configFilename = getConfigFilename(config.network!);
    console.log(`💾 Deployment state saved to: ${deploymentsFilename}`);
    console.log(`⚙️  Configuration saved to: ${configFilename}\n`);
}

/**
 * Main deployment function for testnet
 */
async function deploymentTestnet(config: DeploymentConfig): Promise<void> {
    // Set network to sepolia for testnet
    config.network = "sepolia";

    await getAccountAddress(config);
    await getStarknetRpcUrl(config, config.network);
    await getOwnerAddress(config);
    await getRateParameters(config);
    await saveConfiguration(config, config.network);
    
    await deployAllContracts(config);
    await saveConfiguration(config, config.network);
}

/**
 * Main deployment function for mainnet
 */
async function deploymentMainnet(config: DeploymentConfig): Promise<void> {
    console.log("⚠️  WARNING: You are deploying to MAINNET!");
    const confirm = await ask("Are you sure you want to continue? [y/N]: ", "bool");
    
    if (!confirm) {
        console.log("Deployment cancelled.");
        return;
    }

    // Set network to mainnet
    config.network = "mainnet";

    await getAccountAddress(config);
    await getStarknetRpcUrl(config, config.network);
    await getOwnerAddress(config);
    await getRateParameters(config);
    await saveConfiguration(config, config.network);
    
    await deployAllContracts(config);
    await saveConfiguration(config, config.network);
}

/**
 * Deploy to local devnet
 */
async function deploymentDevnet(config: DeploymentConfig): Promise<void> {
    // Set network and default devnet values
    config.network = "devnet";
    await getAccountAddress(config);
    await getStarknetRpcUrl(config, config.network);
    await getOwnerAddress(config);
    await getRateParameters(config);
    await saveConfiguration(config, config.network);
    
    await deployAllContracts(config);
    await saveConfiguration(config, config.network);
}

// === CLI Interface ==============================================================================

async function main(): Promise<void> {
    const program = new Command();

    program
        .name("deploy-l2")
        .description("A CLI interface for deploying ZeroXBridge L2 contracts on Starknet.")
        .option("--no-config", "Do not use any existing configuration.");

    program
        .command("deploy")
        .description("Interactively deploys the ZeroXBridge L2 contracts on Starknet mainnet.")
        .action(async () => {
            const options = program.opts();
            let config = await loadConfiguration(options.config, "mainnet");
            await deploymentMainnet(config);
        });

    program
        .command("deploy-testnet")
        .description("Interactively deploys the ZeroXBridge L2 contracts on Starknet testnet (Sepolia).")
        .action(async () => {
            const options = program.opts();
            let config = await loadConfiguration(options.config, "sepolia");
            await deploymentTestnet(config);
        });

    program
        .command("deploy-devnet")
        .description("Deploys the ZeroXBridge L2 contracts on local Starknet devnet.")
        .action(async () => {
            const options = program.opts();
            let config = await loadConfiguration(options.config, "devnet");
            await deploymentDevnet(config);
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