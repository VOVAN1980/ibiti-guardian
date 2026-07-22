# 🛡️ IBITI Guardian

<p align="center">
  <img src="assets/logo/icon.png" alt="IBITI Guardian Logo" width="180">
</p>

<p align="center"><b>AI-Powered Voice Assistant & Secure Transaction Guard for Web3 & CEX</b></p>

<p align="center">
  <a href="https://github.com/VOVAN1980/ibiti-guardian">
    <img src="https://img.shields.io/badge/GitHub-Repository-blue?style=for-the-badge&logo=github" alt="GitHub Repo">
  </a>
  <a href="https://vovan1980.github.io/IBITILabs">
    <img src="https://img.shields.io/badge/IBITI-Labs-purple?style=for-the-badge" alt="IBITI Labs">
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-informational?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/flutter-%3E%3D_3.3.4-02569B?style=flat-square&logo=flutter" alt="Flutter">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/platform-Android_|_iOS-3DDC84?style=flat-square&logo=android" alt="Platforms">
</p>

---

**IBITI Guardian** is a secure, non-custodial crypto wallet and CEX controller equipped with a real-time, voice-controlled AI Agent (Jarvis / Guardian AI). 

Designed to combine hands-free voice execution with bank-grade security, Guardian protects Web3 and CEX users through biometric verification, sandbox transaction execution, and strict heuristic policies. It allows users to trade, swap, and transfer crypto purely via voice commands under the safety of a local security shield.

---

## 🎙️ Core Pillars

### 1. Guardian Voice AI (Jarvis)
Hands-free trade execution and market intelligence powered by a customized speech processing pipeline:
- **Speech-to-Text (STT)**: Powered by Whisper, translating raw vocal intents into structured crypto trade orders.
- **Text-to-Speech (TTS)**: Built with OpenAI's model family (GPT-4o / GPT-4o-mini-tts / TTS-1) and optimized using custom pronunciation guidelines for precise crypto speech (e.g., *«Ибити»*, *«Ю-эс-ди-ти»*, *«ор-дер»*).
- **Conversational Feedback**: Concise voice confirmations (e.g., *«Ордер исполнен, удачных торгов.»*) designed to keep speech short, clean, and professional.

### 2. AI Autonomy & Control Modes
Define how much execution authority the AI has:
- **Manual**: Direct manual control. The AI is fully blocked from executing any trade or transaction.
- **Guarded**: Standard operating mode. The AI analyzes market data and requests your explicit authorization (via biometrics/PIN) before signing any transaction.
- **Full Autonomy** *(in development)*: Automatic AI execution. The architecture, policy engine, and market limit infrastructure are fully built to support autonomous trading — the AI will carry out market actions independently, strictly bounded by configured budgets and policy constraints. This mode is not yet available in the current release.

### 3. Heuristic Policy Engine & SandboxGuard
A double-layered shield validating every transaction *before* it leaves your device:
- **SandboxGuard**: Automatically runs a local pre-flight RPC simulation of Web3 transactions to verify execution paths and inspect state changes.
- **Dynamic Policy Checks**: Restricts execution based on daily trade limits, transaction sizes, slippage caps, and price impact (blocking swaps with >5% impact, warning on 1-5%).
- **Reputation Check**: Blocks untrusted contracts and automatically adjusts risk warnings for verified, trusted entities.

### 4. Eternal Permission Kernel (EPK)
An **on-chain permission & policy enforcement** module for Smart Accounts — it governs *what the AI is allowed to do*, and does **not** store keys:
- **On-chain rule enforcement**: per-transaction and daily spend limits, target/selector guards, and threat-feed blocklists, validated against the EPK module deployed on the wallet's chain.
- **Execution modes**: local, guarded, and on-chain EPK enforcement, with a safe fallback path.
- Policy is enforced locally today; the EPK contract is live on **BSC Testnet** (mainnet pending audit — see *Coming Soon*).

### 5. Local Secure Storage
Sensitive data never leaves your device unencrypted:
- Hardware-backed secure storage (`flutter_secure_storage`) plus local biometrics (PIN / FaceID / Fingerprint) to unlock the app.
- Stores wallet metadata, exchange API secrets, and security configuration locally and encrypted. Embedded wallet private keys are managed by **Privy**'s non-custodial wallet infrastructure.

### 6. Multi-Chain Web3 & Centralized Exchange (CEX) Hub
Unified management across DeFi and CeFi:
- **Supported CEXs**: Direct, encrypted API integration for spot trading on **MEXC**, **OKX**, **Gate.io**, and **Binance**.
- **Supported Web3 Networks**: Multi-chain support for **BSC, Ethereum, Polygon, Arbitrum, Optimism, Base, Solana, and Tron**.
- **Embedded Web3 Wallets**: Seamless social login (Google/Apple) and embedded non-custodial wallet creation powered by Privy.

### 🚧 Coming Soon
The following features are architecturally designed and partially implemented, but not yet available in the current release:
- **Autonomous Trading Bot**: The policy engine, market limits, and execution pipeline are built to support fully autonomous AI-driven trading. The bot will operate within strict user-defined budgets, per-transaction caps, and risk thresholds. *(Phase 2)*
- **PassKey Authentication**: WebAuthn/FIDO2 passkey-based authentication for passwordless, phishing-resistant device login. *(Phase 2)*
- **EPK On-Chain Mainnet**: The Eternal Permission Kernel smart contract is deployed on BSC Testnet; mainnet deployment is pending audit completion. Local policy enforcement is fully operational. *(Phase 2)*

---

## 🏗 System Architecture

```mermaid
graph TD
    User([User Voice/UI]) -->|Voice/Text| VoiceTurnController[Voice & Input Controller]
    VoiceTurnController -->|STT Whisper| AssistantService[Guardian Assistant AI]
    AssistantService -->|Intent Parsing| PolicyEngine[Heuristic Policy Engine]
    PolicyEngine -->|Biometric PIN Check| SandboxGuard[SandboxGuard State Simulator]
    SandboxGuard -->|Confirm/Allow| ExecService[Execution Service]
    ExecService -->|API Call| CEX[CEX: MEXC, OKX, Gate.io, Binance]
    ExecService -->|Web3 RPC| Blockchains[Web3: BSC, ETH, Polygon, SOL, TRON]
    
    style PolicyEngine fill:#ff9900,stroke:#333,stroke-width:2px;
    style SandboxGuard fill:#33cc33,stroke:#333,stroke-width:2px;
    style AssistantService fill:#3399ff,stroke:#333,stroke-width:2px;
```

---

## 🛠 Technology Stack

| Component | Technology |
|-----------|------------|
| **Core Framework** | Flutter (Dart SDK >= 3.3.4) |
| **Authentication & Web3** | Privy Flutter SDK (`privy_flutter`) |
| **Database & Cache** | SQLite (`sqflite`) & SharedPreferences |
| **Vault Encryption** | Flutter Secure Storage (`flutter_secure_storage`) |
| **AI Models** | OpenAI GPT-4o / GPT-4o-mini-tts |
| **Voice Processing** | Record (Audio Recording) & Audioplayers (Audio Output) |
| **Local Security** | Local Auth (`local_auth`) for biometrics |

---

## ⚙️ Getting Started

### Requirements
- Flutter SDK (`>= 3.3.4`)
- Android SDK (API Level 28+) / iOS 14+
- OpenAI API Key (Required for voice capabilities)
- Moralis API Key (Required for portfolio balance scan)

### Installation

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/VOVAN1980/ibiti-guardian.git
   cd ibiti-guardian
   flutter pub get
   ```

2. **Setup Credentials**:
   Create a `secrets/` directory inside your root folder and add the following configuration files:
   
   - **`secrets/openai.json`** (OpenAI API credentials):
     ```json
     {
       "apiKey": "YOUR_OPENAI_API_KEY"
     }
     ```
     
   - **`secrets/moralis.json`** (Moralis API for balance querying):
     ```json
     {
       "MORALIS_API_KEY": "YOUR_MORALIS_KEY",
       "CHAIN": "bsc"
     }
     ```
     
   - **`secrets/privy.json`** (Privy SDK credentials):
     ```json
     {
       "PRIVY_APP_ID": "YOUR_PRIVY_APP_ID",
       "PRIVY_CLIENT_ID_ANDROID": "YOUR_ANDROID_CLIENT_ID",
       "PRIVY_CLIENT_ID_IOS": "YOUR_IOS_CLIENT_ID"
     }
     ```

3. **Run the Application**:
   ```bash
   flutter run --release
   ```

---

## 🛡️ License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
