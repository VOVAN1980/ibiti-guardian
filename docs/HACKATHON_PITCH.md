# Hackathon Pitch: IBITI Guardian

## 🛡️ The AI Shield for Web3 & CEX

### 🔴 The Problem
Crypto is dangerous. A single bad signature, a compromised API key, a phishing website, or a simple voice misunderstanding can drain your entire wallet. While AI-driven trading is fast, letting an autonomous AI agent control your real funds without strict boundaries is a recipe for financial disaster.

**There are plenty of "AI crypto apps", but zero protection against AI and user mistakes.**

---

### 🟢 The Solution: IBITI Guardian
IBITI Guardian is the first non-custodial crypto wallet and CEX controller with a built-in **Security Policy Engine** and **Sandbox Simulator** that protects the user from both external threats and the AI itself.

It introduces a **Voice AI assistant (Jarvis)** that lets you interact with Web3 and Spot CEX accounts using simple voice commands, but routes every command through a local security kernel (EPK).

---

### 🚀 Key Value Propositions

1. **Safety Over Speed**: Guardian doesn't just execute; it simulates. If a voice command translates to a trade with >5% price impact, or if the target contract is unverified, Guardian blocks it.
2. **Autonomy with Boundaries**: 
   * *Guarded Mode* keeps the user in control with biometric/PIN confirmations for every AI-proposed trade.
   * *Full Autonomy Mode* allows automated trading, but only within strict daily budgets and limits.
3. **Decentralized & Secure**: Secrets (private keys and CEX API keys) are kept encrypted on-device. CEX API keys with withdrawal permissions enabled are blocked automatically.
4. **Natural User Experience**: Conversational voice confirmations and simplified screen cards replace complex, technical transaction logs and raw alphanumeric IDs.

---

### 🏆 Hackathon Focus: The "Safety-First" AI Agent
While other teams focus on how fast their AI can buy a token, IBITI Guardian focuses on how safely it does so. Our presentation highlights:
* **79 Unit Tests** verifying sandbox integrity and policy execution limits.
* **SandboxGuard** pre-flight RPC simulation.
* Local cryptographically encrypted storage.
