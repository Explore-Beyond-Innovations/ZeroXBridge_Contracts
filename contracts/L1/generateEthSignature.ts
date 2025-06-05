import { ethers } from "ethers"; // Only import ethers, as arrayify is no longer a direct export

// Load environment variables from .env file
import dotenv from "dotenv";
dotenv.config();

/**
 * Configuration for the script.
 * Loads privateKey from environment variable.
 */
const config = {
  privateKey: process.env.PRIVATE_KEY || "",
  // The commitment hash must match what your Cairo contract expects.
  commitmentHash: "0x12315b7aa9abd71d79ebe6926844e4612925f04edcd18eb9c687d517f8a674",
};

/**
 * Signs a given commitment hash using an Ethereum wallet and returns the signature components.
 * @param {string} privateKey - The private key of the Ethereum wallet.
 * @param {string} commitmentHash - The hash to be signed (e.g., a Cairo commitment hash).
 * @returns {Promise<Object>} An object containing eth_address, r, s, and y_parity.
 */
async function signCommitment(privateKey, commitmentHash) {
  // 1. Initialize Wallet
  // We don't need a provider for just signing a message locally.
  const wallet = new ethers.Wallet(privateKey);
  console.log("Wallet initialized with address:", wallet.address);

  // 2. Prepare the message for signing
  // ethers.js expects bytes for signMessage.
  // In newer ethers.js v6, use ethers.getBytes instead of arrayify.
  const messageBytes = ethers.getBytes(commitmentHash); // <<< --- IMPORTANT CHANGE HERE
  console.log("Signing commitment hash:", commitmentHash);

  // 3. Sign the message
  const signature = await wallet.signMessage(messageBytes);
  console.log("Raw Signature:", signature);

  // 4. Extract signature components
  // ethers.Signature.from parses the raw signature string into r, s, and v components.
  const { r, s, v } = ethers.Signature.from(signature);

  // Calculate y_parity (v % 2 === 1)
  const yParity = v % 2 === 1;

  return {
    eth_address: wallet.address,
    r: r,
    s: s,
    y_parity: yParity,
  };
}

/**
 * Main execution function.
 * Handles the overall flow and error logging.
 */
async function main() {
  try {
    const { privateKey, commitmentHash } = config;

    // Validate inputs (basic check)
    if (!privateKey || !commitmentHash) {
      throw new Error("Missing configuration: privateKey or commitmentHash.");
    }
    if (!privateKey.startsWith("0x")) {
      console.warn("Warning: Private key does not start with '0x'. Ethers.js usually handles this, but it's good practice to include it.");
    }
    if (!commitmentHash.startsWith("0x")) {
        throw new Error("Commitment hash must be a hex string and start with '0x'.");
    }

    const result = await signCommitment(privateKey, commitmentHash);

    console.log("\n--- Signature Details ---");
    console.log("eth_address:", result.eth_address);
    console.log("r:", result.r);
    console.log("s:", result.s);
    console.log("y_parity:", result.y_parity);
    console.log("-------------------------");

  } catch (error) {
    console.error("\nAn error occurred:");
    console.error(error.message);
    // Log the whole error object for more details if needed
    // console.error(error);
    process.exit(1); // Exit with a non-zero code to indicate failure
  }
}

// Execute the main function
main();