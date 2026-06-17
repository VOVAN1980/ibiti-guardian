import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ibiti_guardian/utils/base58.dart';

// ── Well-known Solana program addresses ──────────────────────────────────────
/// SPL Token Program
final Uint8List tokenProgramId =
    Base58.decode('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');

/// Associated Token Account Program
final Uint8List associatedTokenProgramId =
    Base58.decode('ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL');

/// System Program
final Uint8List systemProgramId =
    Base58.decode('11111111111111111111111111111111');

/// Sysvar Rent (required for CreateATA instruction)
final Uint8List sysvarRentId =
    Base58.decode('SysvarRent111111111111111111111111111111111');

/// SPL Token transfer instruction discriminator
const int splTransferDiscriminator = 3;

// ── PDA Derivation ──────────────────────────────────────────────────────────

/// Derives the Associated Token Account (ATA) address for a wallet + mint.
///
/// Uses the standard PDA derivation:
///   seeds = [walletPubkey, TOKEN_PROGRAM_ID, mintPubkey]
///   programId = ASSOCIATED_TOKEN_PROGRAM_ID
///
/// Returns the Base58-encoded ATA address.
String deriveAtaAddress({
  required String walletAddress,
  required String mintAddress,
}) {
  final walletPubkey = Base58.decode(walletAddress);
  final mintPubkey = Base58.decode(mintAddress);

  // Try bump seeds from 255 down to 0 (standard PDA derivation)
  for (int bump = 255; bump >= 0; bump--) {
    // Hash input = seeds || programId || "ProgramDerivedAddress"
    // seeds = [walletPubkey, tokenProgramId, mintPubkey, bump]
    final hashInput = BytesBuilder();
    hashInput.add(walletPubkey);
    hashInput.add(tokenProgramId);
    hashInput.add(mintPubkey);
    hashInput.addByte(bump);
    hashInput.add(associatedTokenProgramId);
    hashInput.add('ProgramDerivedAddress'.codeUnits);

    final hash = sha256.convert(hashInput.toBytes()).bytes;

    // A valid PDA must NOT be on the ed25519 curve.
    if (!_isOnEd25519Curve(Uint8List.fromList(hash))) {
      return Base58.encode(Uint8List.fromList(hash));
    }
  }

  throw StateError('Could not derive ATA address — no valid bump found');
}

// ── Ed25519 Curve Check ─────────────────────────────────────────────────────
//
// Ed25519 curve: -x² + y² = 1 + d·x²·y²  (mod p)
// p = 2²⁵⁵ - 19
// d = -121665/121666 mod p
//
// To check if a 32-byte value is on the curve:
// 1. Decode as little-endian integer (clear sign bit = bit 255) → y
// 2. If y >= p → not on curve
// 3. Compute u = y² - 1 mod p
// 4. Compute v = d·y² + 1 mod p
// 5. Check if u·v⁻¹ mod p is a quadratic residue (Euler criterion)

/// Ed25519 prime: 2²⁵⁵ - 19
final BigInt _p = BigInt.two.pow(255) - BigInt.from(19);

/// Ed25519 curve constant d = -121665 * modInverse(121666, p) mod p
final BigInt _d =
    (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;

/// Returns true if the 32-byte value represents a valid ed25519 public key.
bool _isOnEd25519Curve(Uint8List bytes) {
  if (bytes.length != 32) return false;

  // Decode y-coordinate (little-endian, clear sign bit)
  final yBytes = Uint8List.fromList(bytes);
  yBytes[31] = yBytes[31] & 0x7F; // Clear sign bit (bit 255)

  BigInt y = BigInt.zero;
  for (int i = 0; i < 32; i++) {
    y += BigInt.from(yBytes[i]) << (8 * i);
  }

  // y must be < p
  if (y >= _p) return false;

  // Curve equation: -x² + y² = 1 + d·x²·y²
  // Rearranged: x² = (y² - 1) / (d·y² + 1) mod p
  final y2 = (y * y) % _p;
  final u = (y2 - BigInt.one) % _p; // numerator
  final v = (_d * y2 + BigInt.one) % _p; // denominator

  if (v == BigInt.zero) return false; // Degenerate case

  // x² = u · v⁻¹ mod p
  final vInv = v.modInverse(_p);
  final x2 = (u * vInv) % _p;

  if (x2 == BigInt.zero) return true; // x = 0 is on the curve

  // Euler's criterion: x² is a quadratic residue iff x²^((p-1)/2) ≡ 1 (mod p)
  final exp = (_p - BigInt.one) >> 1; // (p - 1) / 2
  final result = x2.modPow(exp, _p);

  return result == BigInt.one;
}

// ── Transaction Builders ────────────────────────────────────────────────────

/// Compact-u16 encoder for Solana binary format.
Uint8List _encodeLength(int len) {
  if (len < 0x80) return Uint8List.fromList([len]);
  if (len < 0x4000) return Uint8List.fromList([len | 0x80, len >> 7]);
  return Uint8List.fromList([len | 0x80, (len >> 7) | 0x80, len >> 14]);
}

/// Builds a complete Solana transaction for SPL token transfer.
///
/// If [destinationAtaExists] is false, prepends a CreateAssociatedTokenAccount
/// instruction before the SPL transfer — a single atomic transaction.
Uint8List buildSplTransferTransaction({
  required String fromAddress,
  required String toAddress,
  required String mintAddress,
  required String sourceAtaAddress,
  required String? destinationAtaAddress,
  required bool destinationAtaExists,
  required BigInt amount,
  required String recentBlockhash,
}) {
  final fromPubkey = Base58.decode(fromAddress);
  final toPubkey = Base58.decode(toAddress);
  final mintPubkey = Base58.decode(mintAddress);
  final sourceAta = Base58.decode(sourceAtaAddress);
  final recentHash = Base58.decode(recentBlockhash);

  // Derive or use provided destination ATA
  final destAtaAddr = destinationAtaAddress ??
      deriveAtaAddress(
        walletAddress: toAddress,
        mintAddress: mintAddress,
      );
  final destAta = Base58.decode(destAtaAddr);

  if (destinationAtaExists) {
    // ── Simple transfer: destination ATA already exists ────────────────────
    return _buildSimpleTransferTx(
      fromPubkey: fromPubkey,
      sourceAta: sourceAta,
      destAta: destAta,
      amount: amount,
      recentHash: recentHash,
    );
  } else {
    // ── CreateATA + Transfer: 2 instructions in one atomic tx ─────────────
    return _buildCreateAtaAndTransferTx(
      fromPubkey: fromPubkey,
      toPubkey: toPubkey,
      mintPubkey: mintPubkey,
      sourceAta: sourceAta,
      destAta: destAta,
      amount: amount,
      recentHash: recentHash,
    );
  }
}

/// Simple SPL transfer (dest ATA exists).
///
/// Accounts: [owner(signer), sourceATA(writable), destATA(writable), tokenProgram(readonly)]
/// Header: [1 signer, 0 readonly signed, 1 readonly unsigned]
Uint8List _buildSimpleTransferTx({
  required Uint8List fromPubkey,
  required Uint8List sourceAta,
  required Uint8List destAta,
  required BigInt amount,
  required Uint8List recentHash,
}) {
  // Header: 1 signer, 0 readonly signed, 1 readonly unsigned (tokenProgram)
  final header = Uint8List.fromList([1, 0, 1]);

  const numAccounts = 4;
  final accountKeys = Uint8List(32 * numAccounts);
  accountKeys.setAll(0, fromPubkey); // 0: signer (writable)
  accountKeys.setAll(32, sourceAta); // 1: source ATA (writable)
  accountKeys.setAll(64, destAta); // 2: dest ATA (writable)
  accountKeys.setAll(96, tokenProgramId); // 3: Token Program (readonly)

  // Transfer instruction data: [discriminator(1)] [amount(8)]
  final instrData = ByteData(9);
  instrData.setUint8(0, splTransferDiscriminator);
  instrData.setUint64(1, amount.toInt(), Endian.little);

  final messageBuilder = BytesBuilder();
  messageBuilder.add(header);
  messageBuilder.add(_encodeLength(numAccounts));
  messageBuilder.add(accountKeys);
  messageBuilder.add(recentHash);
  messageBuilder.add(_encodeLength(1)); // 1 instruction

  // SPL Transfer instruction
  messageBuilder.addByte(3); // Program ID index (tokenProgram)
  messageBuilder.add(_encodeLength(3)); // 3 account indices
  messageBuilder.addByte(1); // source ATA
  messageBuilder.addByte(2); // dest ATA
  messageBuilder.addByte(0); // owner (signer)
  messageBuilder.add(_encodeLength(instrData.lengthInBytes));
  messageBuilder.add(instrData.buffer.asUint8List());

  final messageBytes = messageBuilder.toBytes();
  final txBuilder = BytesBuilder();
  txBuilder.addByte(1); // 1 signature
  txBuilder.add(Uint8List(64)); // placeholder signature
  txBuilder.add(messageBytes);
  return txBuilder.toBytes();
}

/// CreateATA + SPL Transfer in one atomic transaction.
///
/// Account keys (7 total):
///   0: payer/owner     (signer, writable)
///   1: source ATA      (writable)
///   2: dest ATA        (writable) — will be created
///   3: recipient       (readonly)
///   4: mint            (readonly)
///   5: system program  (readonly)
///   6: token program   (readonly)
///
/// (Associated Token Program is used as the program ID for the CreateATA
/// instruction — but it's referenced by index from supportedChains, so we
/// need it in the accounts list too. Actually the ATA program is the
/// instruction's program ID, not an account. Let me correct this.)
///
/// For CreateATA the program ID is the Associated Token Program.
/// For Transfer the program ID is the Token Program.
/// Both must be in the accounts list.
///
/// Final account keys (8 total):
///   0: payer/owner            (signer, writable)
///   1: source ATA             (writable)
///   2: dest ATA               (writable)
///   3: recipient wallet       (readonly)
///   4: mint                   (readonly)
///   5: system program         (readonly)
///   6: token program          (readonly)
///   7: ATA program            (readonly)
///
/// Header: [1 signer, 0 readonly signed, 5 readonly unsigned (indices 3-7)]
Uint8List _buildCreateAtaAndTransferTx({
  required Uint8List fromPubkey,
  required Uint8List toPubkey,
  required Uint8List mintPubkey,
  required Uint8List sourceAta,
  required Uint8List destAta,
  required BigInt amount,
  required Uint8List recentHash,
}) {
  // Header: 1 signer, 0 readonly signed, 5 readonly unsigned
  final header = Uint8List.fromList([1, 0, 5]);

  const numAccounts = 8;
  final accountKeys = Uint8List(32 * numAccounts);
  accountKeys.setAll(0, fromPubkey); // 0: payer/owner (signer, writable)
  accountKeys.setAll(32, sourceAta); // 1: source ATA (writable)
  accountKeys.setAll(64, destAta); // 2: dest ATA (writable)
  accountKeys.setAll(96, toPubkey); // 3: recipient (readonly)
  accountKeys.setAll(128, mintPubkey); // 4: mint (readonly)
  accountKeys.setAll(160, systemProgramId); // 5: system program (readonly)
  accountKeys.setAll(192, tokenProgramId); // 6: token program (readonly)
  accountKeys.setAll(
      224, associatedTokenProgramId); // 7: ATA program (readonly)

  // Transfer instruction data
  final transferData = ByteData(9);
  transferData.setUint8(0, splTransferDiscriminator);
  transferData.setUint64(1, amount.toInt(), Endian.little);

  final messageBuilder = BytesBuilder();
  messageBuilder.add(header);
  messageBuilder.add(_encodeLength(numAccounts));
  messageBuilder.add(accountKeys);
  messageBuilder.add(recentHash);
  messageBuilder.add(_encodeLength(2)); // 2 instructions

  // ── Instruction 1: CreateAssociatedTokenAccount ──────────────────────────
  // Program: ATA Program (index 7)
  // Accounts: [payer(0), destATA(2), recipient(3), mint(4), systemProgram(5), tokenProgram(6)]
  // Data: empty (CreateATA has no instruction data)
  messageBuilder.addByte(7); // Program ID index (ATA program)
  messageBuilder.add(_encodeLength(6)); // 6 account indices
  messageBuilder.addByte(0); // payer
  messageBuilder.addByte(2); // dest ATA (to be created)
  messageBuilder.addByte(3); // recipient wallet
  messageBuilder.addByte(4); // mint
  messageBuilder.addByte(5); // system program
  messageBuilder.addByte(6); // token program
  messageBuilder.add(_encodeLength(0)); // no data

  // ── Instruction 2: SPL Transfer ─────────────────────────────────────────
  // Program: Token Program (index 6)
  // Accounts: [sourceATA(1), destATA(2), owner(0)]
  messageBuilder.addByte(6); // Program ID index (token program)
  messageBuilder.add(_encodeLength(3)); // 3 account indices
  messageBuilder.addByte(1); // source ATA
  messageBuilder.addByte(2); // dest ATA
  messageBuilder.addByte(0); // owner (signer)
  messageBuilder.add(_encodeLength(transferData.lengthInBytes));
  messageBuilder.add(transferData.buffer.asUint8List());

  final messageBytes = messageBuilder.toBytes();
  final txBuilder = BytesBuilder();
  txBuilder.addByte(1); // 1 signature
  txBuilder.add(Uint8List(64)); // placeholder signature
  txBuilder.add(messageBytes);
  return txBuilder.toBytes();
}
