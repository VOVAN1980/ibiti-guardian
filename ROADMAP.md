# Roadmap

This roadmap outlines the planned development phases for IBITI Guardian as it evolves from a hackathon MVP to a fully production-ready security assistant.

---

##  Phase 1: Hackathon Release (Current)
- [x] **Voice AI Core**: Stable Whisper STT and custom GPT-4o TTS optimized for crypto terminology and clear Russian/English output.
- [x] **Heuristic Policy Engine**: Enforcement of per-transaction limits, daily budgets, minimum order size, and allowed networks/tokens.
- [x] **SandboxGuard**: RPC transaction pre-flight simulation and state checking before execution.
- [x] **CEX Spot trading**: API integrations for MEXC, Gate.io, OKX, and Binance.
- [x] **Web3 Integrations**: Privy social auth + embedded wallet.

---

## 📅 Phase 2: Advanced Safety & Automation (Q3 2026)
- [ ] **Autonomous Trading Bot**: Activate the fully autonomous AI trading mode. The policy engine, market limits, price-impact guards, and execution pipeline are already architected — the bot will operate within strict user-defined budgets and risk thresholds without manual confirmation.
- [ ] **PassKey Authentication**: Implement WebAuthn/FIDO2 passkey-based login for passwordless, phishing-resistant device authentication.
- [ ] **EPK On-Chain Mainnet**: Deploy the Eternal Permission Kernel smart contract to BSC/Ethereum mainnet after security audit (currently live on BSC Testnet).
- [ ] **Automated Attack Mitigation**: Real-time mempool monitoring to trigger automated revokes or panic actions if threat signatures are detected.
- [ ] **Custom AI Prompt Tuning**: Ability to train Jarvis on personalized investor profiles and custom risk tolerance models.
- [ ] **Multi-Agent Collaboration**: Integration of secondary validator subagents to verify the primary AI's proposed decisions.
- [ ] **Frictionless Gas Abstraction**: Pay Web3 gas fees in stablecoins (USDT/USDC) using account abstraction (ERC-4337).

---

## ЁЯУЕ Phase 3: Cross-Chain Expansion & Ecosystem (Q4 2026)
- [ ] **Cross-Chain Voice Swaps**: Route cross-chain swaps between EVM, Solana, and Tron with single voice commands.
- [ ] **Hardware Wallet Integrations**: Support Ledger and Trezor hardware signing via companion app.
- [ ] **Community Threat Database**: Live synchronization of blacklist addresses directly from community security feeds.
